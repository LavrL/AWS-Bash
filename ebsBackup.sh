#!/bin/bash

#Script for rotating AWS snapshots. 
#This script does the following:
#1. Create snapshot of instance.
#2. Delete snapshot that older than n days(default 15 days)
#3. Write all information about backup process in log file

#Exit script if any error occured
set -eu
set -o pipefail

instanceId=$(wget -qO- http://instance-data/latest/meta-data/instance-id)
#echo $instanceId
region=$(wget -qO- http://169.254.169.254/latest/meta-data/placement/availability-zone |sed s'/.$//')
#echo $region

logFile='/var/log/ebslog.log'
logFilesize=5000
#Check if all programs for script are installed

CheckRequirements(){

tools=(wget aws)
for tool in ${tools[*]}; do
    command -v $tool >/dev/null 2>&1 || { echo $tool "is required, but it's not installed.  Aborting." >&2; exit 1; }
done

}

#Logging for script
SnapshotLogging() {

# Check if log file exists and writable
( [ -e "$logFile" ] || [ touch "$logFile" ] ) && [ ! -w "$logFile" ] && echo "Not writable" && exit 1 
# Leave only last 5000 rows in log file
echo "$(tail -n $logFilesize /var/log/ebslog.log)" > "/var/log/ebslog.log"

exec >> "/var/log/ebslog.log" 2>&1

echo " "
echo $instanceId
echo $region

}

# Create snapshots

CreateBackup() {

volumeList=$(aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instanceId --query 'Volumes[*].{ID:VolumeId}' --output text)
echo $volumeList

for volume in $volumeList; do
    deviceName=$(aws ec2 describe-volumes --region $region --region $region --volume-ids $volume --query 'Volumes[0].{Devices:Attachments[0].Device}' --output=text)
	
    snapshotId=$(aws ec2 create-snapshot --region $region --volume-id $volume --description "$instanceId-$deviceName" --query SnapshotId --output text)
    echo "Created snapshot from volume - " $volume
	
	aws ec2 create-tags --region $region --resources $snapshotId --tags Key=TakenBy,Value=AutomatedBackup
	echo "Snapshot was tagged"
done
}

#Search for snapshots and delete snapshots > 15 days old

OldSnapshotsBackup() {

dateRetention=$(date -d '-15 day' '+%s')

for volume in $volumeList; do
    snapshotsList=$(aws ec2 describe-snapshots --region $region --filter "Name=volume-id,Values=$volume" "Name=tag:TakenBy,Values=AutomatedBackup" --query 'Snapshots[*].{ID:SnapshotId}' --output text)
	    for snapshot in $snapshotsList; do
		    snapshotDate=$(aws ec2 describe-snapshots --region $region --snapshot-id $snapshot --query 'Snapshots[*].{Time:StartTime}' --output text  | cut -d T -f 1)
			snapshotDateInSeconds=$(date "--date=$snapshotDate" +%s)
			if (( $snapshotDateInSeconds <= $dateRetention )); then
			    echo "Deleting snapshot - " $snapshot
			    aws ec2 delete-snapshot --region $region --snapshot-id $snapshot
			fi
		done
done
}

SnapshotLogging
CheckRequirements
CreateBackup
OldSnapshotsBackup
