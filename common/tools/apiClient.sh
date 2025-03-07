#!/bin/bash

# Title: Androidacy API shell client
# Description: Provides an interface to the Androidacy API
# License: AOSL
# Version: 2.1.8
# Author: Androidacy or it's partners

# JSON parser
parseJSON() {
    echo "$1" | sed 's/[{}]/''/g' | awk -v k="text" '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed 's/[\,]/ /g' | sed 's/\"//g' | grep -w "$2" | cut -d"|" -f2
}

# Initiliaze API logging. Currently, nothing is sent off device, but this may change in the future.
export logfile android device lang
if [ ! -d /sdcard/.androidacy ]; then
  mkdir -p /sdcard/.androidacy
fi
logfile="/sdcard/.androidacy/api.log"
android=$(resetprop ro.system.build.version.release || resetprop ro.build.version.release)
device=$(resetprop ro.product.model | sed 's#\n#%20#g' || resetprop ro.product.device | sed 's#\n#%20#g' || resetprop ro.product.vendor.device | sed 's#\n#%20#g' || resetprop ro.product.system.model | sed 's#\n#%20#g' || resetprop ro.product.vendor.model | sed 's#\n#%20#g' || resetprop ro.product.name | sed 's#\n#%20#g')
# Imternal beta testers only: enables translated strings
lang=$(resetprop persist.sys.locale | sed 's#\n#%20#g' || resetprop ro.product.locale | sed 's#\n#%20#g')
{
  echo "=== Device info ==="
  echo "Device: $device"
  echo "Android: $android"
  echo "Lang: $lang"
  echo "==================="
} > $logfile
api_log() {
  local level=$1
  local message=$2
  echo "[$1] $2" >> $logfile
}

# Initiliaze the API
initClient() {
    # We need to get the module codename and version
    # We have to extract this from module.prop
    # Make sure $api_mpath is set
    if [ -n "$MODPATH" ]; then
      export api_mpath=$MODPATH
    else
      export api_mpath="echo $(dirname "$0") | sed 's/\//\ /g' | awk  '{print $4}'"
    fi
    export MODULE_CODENAME MODULE_VERSION MODULE_VERSIONCODE fail_count
    fail_count=0
    MODULE_CODENAME=$(grep "id=" "$api_mpath"/module.prop | cut -d"=" -f2)
    MODULE_VERSION=$(grep "version=" "$api_mpath"/module.prop | cut -d"=" -f2)
    MODULE_VERSIONCODE=$(grep "versionCode=" "$api_mpath"/module.prop | cut -d"=" -f2)
    api_log 'INFO' "Initializing API with paramaters: $1, $2"
    # Warn if they pass arguments to initClient, as this is legacy behaviour
    if [ "$1" != "" ] || [ "$2" != "" ]; then
        api_log 'WARN' "initClient() has been called with arguments, this is legacy behaviour and will be removed in the future"
    fi
    export API_URL='https://api.androidacy.com'
    buildClient
    initTokens
    export __init_complete=true
}

# Build client requests
buildClient() {
    api_log 'INFO' "Building client and exporting variables"
    export API_UA="Mozilla/5.0 (Linux; Android $android; $device) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Mobile Safari/537.36"
    export API_LANG=$lang
}

# Tokens init
initTokens() {
    api_log 'INFO' "Starting tokens initialization"
    if test -f /sdcard/.androidacy/credentials.json; then
        api_credentials=$(cat /sdcard/.androidacy/credentials.json)
    else
        api_log 'WARN' "Couldn't find API credentials. If this is a first run, this warning can be safely ignored."
        wget --no-check-certificate --post-data "{}" -qU "$API_UA" --header "Accept-Language: $API_LANG" "https://api.androidacy.com/auth/register" -O /sdcard/.androidacy/credentials.json
        api_credentials="$(cat /sdcard/.androidacy/credentials.json)"
        sleep 0.5
    fi
    api_log 'INFO' "Exporting token"
    export api_credentials
    validateTokens "$api_credentials"
}

# Check that we have a valid token
validateTokens() {
    api_log 'INFO' "Starting tokens validation"
    if test "$#" -ne 1; then
        api_log 'ERROR' 'Caught error in validateTokens: wrong arguments passed'
        echo "Illegal number of parameters passed. Expected one, got $#"
        abort
    else
        tier=$(parseJSON $(wget --no-check-certificate -qU "$API_UA" --header "Authorization: $api_credentials" --header "Accept-Language: $API_LANG" "$API_URL/auth/me" -O -) 'level' | sed 's/level://g')
        if test $? -ne 0; then
            api_log 'WARN' "Got invalid response when trying to validate token!"
            # Restart process on validation failure. Make sure we only do this 3 times!!
            if [ "$fail_count" -lt 3 ]; then
                fail_count=$((fail_count + 1))
                api_log 'INFO' "Restarting process for the $fail_count time"
                rm -f '/sdcard/.androidacy/credentials.json'
                sleep 1
                initTokens
            else
                api_log 'ERROR' "Failed to validate token after $fail_count attempts. Aborting."
                abort
            fi
        else
            # Pass the appropriate API access level back to the caller
            export tier
        fi
    fi
    if test "$tier" -lt 2; then
        echo '- Looks like you are using guest credentials'
        echo '- Get faster downloads and support development - https://www.androidacy.com/donate/'
        export sleep=0.5
        export API_URL='https://api.androidacy.com'
    else
        export sleep=0.5
        export API_URL='https://api.androidacy.com'
    fi
}

# Handle and decode file list JSON
getList() {
    api_log 'INFO' "getList called with parameter: $1"
    if test "$#" -ne 1; then
        api_log 'ERROR' 'Caught error in getList: wrong arguments passed'
        echo "Illegal number of parameters passed. Expected one, got $#"
        abort
    else
        if ! $__init_complete; then
            api_log 'ERROR' 'Make sure you initialize the api client via initClient before trying to call API methods'
            echo "Tried to call getList without first initializing the API client!"
            abort
        fi
        local app=$MODULE_CODENAME
        local cat=$1
        if test "$app" = 'beta' && test tier -lt 4; then
            echo "Error! Access denied for beta."
            abort
        fi
        response=$(wget --no-check-certificate -qU "$API_UA" --header "Authorization: $api_credentials" --header "Accept-Language: $API_LANG" "$API_URL/downloads/list/v2?app=$app&category=$cat&simple=true" -O -)
        if test $? -ne 0; then
            api_log 'ERROR' "Couldn't contact API. Is it offline or blocked?"
            echo "API request failed! Assuming API is down and aborting!"
            abort
        fi
        sleep $sleep
        # shellcheck disable=SC2001
        parsedList=$(echo "$response" | sed 's/[^a-zA-Z0-9]/ /g')
        response="$parsedList"
    fi
}

# Handle file downloads
downloadFile() {
    api_log 'INFO' "downloadFile called with parameters: $1 $2 $3 $4"
    if test "$#" -ne 4; then
        api_log 'ERROR' 'Caught error in downloadFile: wrong arguments passed'
        echo "Illegal number of parameters passed. Expected four, got $#"
        abort
        if ! $__init_complete; then
            api_log 'ERROR' 'Make sure you initialize the api client via initClient before trying to call API methods'
            echo "Tried to call downloadFile without first initializing the API client!"
            abort
        fi
    else
        local cat=$1
        local file=$2
        local format=$3
        local location=$4
        local app=$MODULE_CODENAME
        local link=$(parseJSON $(wget --no-check-certificate -qU "$API_UA" --header "Authorization: $api_credentials" --header "Accept-Language: $API_LANG" "$API_URL/downloads/link/v2?app=$app&category=$cat&file=$file.$format" -O -) 'link')
        wget --no-check-certificate -qU "$API_UA" --header "Authorization: $api_credentials" --header "Accept-Language: $API_LANG" "$(echo $link | sed 's/\\//gi' | sed 's/\ //gi')" -O "$location"
        if test $? -ne 0; then
            api_log 'ERROR' "Couldn't contact API. Is it offline or blocked?"
            echo "API request failed! Assuming API is down and aborting!"
            abort
        fi
        sleep $sleep
    fi
}

# Handle uptdates checking
updateChecker() {
    api_log 'INFO' "updateChecker called with parameter: $1"
    if test "$#" -ne 1; then
        api_log 'ERROR' 'Caught error in updateChecker: wrong arguments passed'
        echo "Illegal number of parameters passed. Expected one, got $#"
        abort
        if ! $__init_complete; then
            api_log 'ERROR' 'Make sure you initialize the api client via initClient before trying to call API methods'
            echo "Tried to call updateChecker without first initializing the API client!"
            abort
        fi
    else
        local cat=$1 || 'self'
        local app=$MODULE_CODENAME
        response=$(wget --no-check-certificate -qU "$API_UA" --header "Authorization: $api_credentials" --header "Accept-Language: $API_LANG" "$API_URL/downloads/updates?app=$app&category=$cat" -O -)
        sleep $sleep
        # shellcheck disable=SC2001
        response=$(parseJSON "$response" "version")
    fi
}

# Handle checksums
getChecksum() {
    api_log 'INFO' "getChecksum called with parameters: $1 $2 $3"
    if test "$#" -ne 3; then
        api_log 'ERROR' 'Caught error in getChecksum: wrong arguments passed'
        echo "Illegal number of parameters passed. Expected three, got $#"
        abort
        if ! $__init_complete; then
            api_log 'ERROR' 'Make sure you initialize the api client via initClient before trying to call API methods'
            echo "Tried to call getChecksum without first initializing the API client!"
            abort
        fi
    else
        local cat=$1
        local file=$2
        local format=$3
        local app=$MODULE_CODENAME
        res=$(wget --no-check-certificate -qU "$API_UA" --header "Authorization: $api_credentials" --header "Accept-Language: $API_LANG" "$API_URL/checksum/get?app=$app&category=$cat&request=$file&format=$format" -O -)
        if test $? -ne 0; then
            api_log 'ERROR' "Couldn't contact API. Is it offline or blocked?"
            echo "API request failed! Assuming API is down and aborting!"
            abort
        fi
        sleep $sleep
        response=$(parseJSON "$res" 'checksum')
    fi
}
