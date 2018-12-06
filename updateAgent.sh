#!/bin/bash

# Cosimo Simeone - 06/11/2018 - OS Update agent
# CAS-06386-W0G2P4 - LinuxPatching

## CHANGELOG:
## 20181106 - Added comments
## 20181206 - Added filesystem usage check
##


#set -x

###########################################################################
### Initial setup
###########################################################################

# If DEBUG variable is not set, assume it is 0 (no backup)
: ${DEBUG:=0}

### FileSystem check limit
# Please put here DECIMAL digit for limit.
# If you want to be alerted for FS usage > 80%, put export FILESYSTEM_PCT_LIMIT=8
# If you want to be alerted for FS usage > 70%, put export FILESYSTEM_PCT_LIMIT=7
# And so on
export FILESYSTEM_PCT_LIMIT=8

### Aliasing some custom echo commands
shopt -s expand_aliases
alias echoi='echo `date +%Y-%m-%d\ %H:%M.%S` -INFO-'
alias echow='echo `date +%Y-%m-%d\ %H:%M.%S` ---WARNING---'
alias echoe='echo ERR- `date +%Y-%m-%d\ %H:%M.%S` -ERROR-'
alias echod='[ $DEBUG -ne 0 ] && echo -- `date +%Y-%m-%d\ %H:%M.%S` -DEBUG-'

### Directory and files configuration
export communicationDir=/var/www/html/linuxPatchingSharedDir/`hostname`
mkdir -p $communicationDir

export updateAtTime_file=$communicationDir/UPDATE_YOURSELF
export needUpdate_file=$communicationDir/I_NEED_2B_UPDATE
export needUpdate_tmpFile=$communicationDir/I_NEED_2B_UPDATE.tmp
export needReboot_file=$communicationDir/I_NEED_2B_REBOOTED
export filesystemFull_file=$communicationDir/FILESYSTEM_FULL
export filesystemFull_tmpFile=$communicationDir/FILESYSTEM_FULL.tmp

export LOGFILE=$communicationDir/`basename "$0"`.log
export ERRORFILE=$communicationDir/`basename "$0"`.error


# This code needs root privileges to install updates; if it is executed via non-root user, exit
if [ "$EUID" -ne 0 ]; then
  echoe "Please run as root" | tee -a $LOGFILE
  exit 1
fi


### Function declaration

# This function checks wether there are updates available, by calling apr-get with -s ("Simulate") parameter
function checkUpdatesAvailable {
  rm -f $needUpdate_file
  apt-get update > /dev/null  2>>$LOGFILE
  apt-get upgrade -s -d -y | tee $needUpdate_tmpFile | grep "The following packages will be upgraded" > /dev/null 2>>$LOGFILE
  retVal=$?
  echod "checkUpdatesAvailable retVal=$retVal"
  return $retVal
}

# This function installs updates
# Notes:
# * -o Dpkg::Options:: options are passed to tell apt-get to keep original configuration files,
#     since apt-get is executed in noninteractive mode
function installAvailableUpdates {
  rm -f $ERRORFILE
  rm -f $needReboot_file
  apt-get update >> $LOGFILE  2>&1
  DEBIAN_FRONTEND=noninteractive \
   apt-get \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"   \
    upgrade -yqV \
   >>$LOGFILE 2>&1
  retVal=$?
  echod "checkUpdatesAvailable retVal=$retVal"
  if [[ $retVal -ne 0 ]]; then
    echoe "!!! ERROR IN UPGRADES, PLEASE CHECK !!!"| tee -a $LOGFILE
    echoe "!!! ERROR IN UPGRADES, PLEASE CHECK !!!" > $ERRORFILE
    exit $retVal
  else
    rm -f $ERRORFILE
  fi
}

# After an update, server might need to be rebooted. Check funcion defined here
function checkRebootNeeded {
  # Notify reboot needed
  if [[ -f /var/run/reboot-required ]]; then
    echoi "REBOOT ME" > $needReboot_file
    cat /var/run/reboot-required.pkgs >> $needReboot_file 2>/dev/null
    echod "Reboot needed"
  else
    rm -f $needReboot_file
    echod "No reboot needed"
  fi
}


# For testing purpose, do not use in productin
function DEMO_installAvailableUpdates_DEMO {
  echo "******* FAKE DEMO ***** OK DONE!" | tee -a $LOGFILE
  echod "FAKE update function called, no update applied on system"
}


# This function checks filesystem usage
function checkFilesystemUsage {
  echod "Checking FS usage"
  rm -f $filesystemFull_file
  df -h | grep -E "([$FILESYSTEM_PCT_LIMIT-9][0-9]\%|100\%)" > $filesystemFull_tmpFile 2> /dev/null
  retVal=$?
  echod "checkFilesystemUsage retVal=$retVal"
  if [[ $retVal -eq 0 ]]; then
    echoi "Some filesystem might need a cleanup"  >>$LOGFILE
    mv -f $filesystemFull_tmpFile $filesystemFull_file
  else
    echoi "All FS below threshold"  >>$LOGFILE
    rm -f $filesystemFull_tmpFile $filesystemFull_file
  fi

}



###########################################################################
####### MAIN part
###########################################################################

# Double check
#  This should never happen, but better check, couse if it happens, there are trubles in error handling above
if [[ -f $ERRORFILE ]]; then
   echoe "!!!  ERRORFILE FILE EXISTS WHERE IT SHOULD NOT EXIST; EXITING NOW !!!" | tee -a $LOGFILE
   echoe "!!!    YOU'D BETTER CHECK WHAT HAPPENED                           !!!" | tee -a $LOGFILE
   echoe "ERRORFILE=$ERRORFILE" | tee -a $LOGFILE
   exit 99
fi


### Check if we need updates, and notify
# if checkUpdatesAvailable -eq 1 ; then
checkUpdatesAvailable
updatesAvailable=$?

if [[ $updatesAvailable -ne 0 ]]; then

  # No updates available. Notify it, and exit with success
  echoi "No updates available" >>$LOGFILE
  rm -f $needUpdate_file $needUpdate_tmpFile

  # IMPORTANT: assumption here is: "you asked to update system, but no updates available",
  #  hence maybe you made a mistake, or this file is here like "Yeh, whatever, apply the update".
  # We stay on a safe-side: update just when necessary, and when explicitly and consciously asked.
  if [[ -f $updateAtTime_file ]]; then
    echoi "$updateAtTime_file file exists, IT WILL BE DELETED NOW" >>$LOGFILE
    rm -f $updateAtTime_file
  fi


else #if [[ $updatesAvailable -ne 0 ]]; then


  ### Executing being here means: there are updates available
  echoi "There are updates Available" >>$LOGFILE
  mv -f $needUpdate_tmpFile $needUpdate_file

  # Now check: have i being asked to install them?
  if [[ -f $updateAtTime_file ]]; then

    echod "File $updateAtTime_file exists"

    # Oh, and just in case, trim spaces, convert to unix, and just take 1st line in file
    [[ -s $updateAtTime_file ]] && export inTime=`head -1 $updateAtTime_file | tr -d '\015 '`

    # Assuming here: "file existing, but with empty line in it; that means "something is wrong"
    # (read above)
    if [ -z "$inTime" ]; then
      echoe "Wrong Date in $updateAtTime_file: |$inTime| is empty" | tee -a $LOGFILE
      touch $ERRORFILE
      exit 1
    fi

    # Check hour passed is a valid hour
    # (10# tells bash this is not an octal number)
    if [[ 10#$inTime -lt 10#0 || 10#$inTime -gt 10#23 ]]; then
      echoe "Wrong Date in $updateAtTime_file: |$inTime|" | tee -a $LOGFILE
      touch $ERRORFILE
      exit 1
    fi

    # Ok. Code is here. So far so good.
    askedDate=$inTime
    actualDate=`date +%H`
    echod " askedDate=$inTime"
    echod actualDate=$actualDate

    # Check if we are in hour asked to be updated
    if [[ 10#$actualDate -ne 10#$askedDate ]]; then
      echoi "Hour |$askedDate| not reached yet, it's still |$actualDate|" >> $LOGFILE
      exit 0
    fi

    ### The real thing is happening here.
    echoi "Applying updates!!! ">> $LOGFILE
    #DEMO_installAvailableUpdates_DEMO
    installAvailableUpdates

    echoi "Applying updates done; removing flag files">> $LOGFILE
    rm -f $updateAtTime_file
    rm -f $needUpdate_file

    echoi "Alles gut, have a nice day">> $LOGFILE
    retVal=0
  else
    ### Here if updates available, but no $updateAtTime_file exists, so nothing to do
    echoi "Flag file does not exist; nothing to do" >> $LOGFILE
    echoi "Expected flag file is $updateAtTime_file" >> $LOGFILE
    retVal=0
  fi

fi #if [[ $updatesAvailable -ne 0 ]]; then


# Check if reboot file needs to be craeted
checkRebootNeeded

# Check Filesystem usage
checkFilesystemUsage

if [[ $retVal -ne 0 ]]; then
  exit $retVal
fi
