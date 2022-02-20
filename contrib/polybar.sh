#!/bin/bash

# See <https://github.com/thisjade/TravelynxPolybar/blob/main/README.md>
# for configuration details

# Interval for refreshing Data and giving it to Polybar
INTERVAL=1

# Delay Notification Variables
notificationDelaySent="false"
notificationLastDelay=0
notificationNextStopSent="true"
notificationNextStopTime=""

# Place your API Key here
API_KEY=
NOTIFICATIONS_NEXT_STOP="true"
NOTIFICATIONS_DELAY="true"
LANGUAGE="DE"
SYMBOL=""


while true; do
	# curl'ing of all needed Data from https://travelynx.de
	isCheckedIn=$(curl -s https://travelynx.de/api/v1/status/$API_KEY | jq .checkedIn | sed 's/"//' | sed 's/"//') 
	echo "$isCheckedIn" > /dev/null;
	trainType=$(curl -s https://travelynx.de/api/v1/status/$API_KEY | jq .train.type | sed 's/"//' | sed 's/"//')
	echo "$trainType" > /dev/null;
	trainNo=$(curl -s https://travelynx.de/api/v1/status/$API_KEY | jq .train.no | sed 's/"//' | sed 's/"//')
	echo "$trainNo" > /dev/null;
	trainLine=$(curl -s https://travelynx.de/api/v1/status/$API_KEY | jq .train.line | sed 's/"//' | sed 's/"//')
	echo "$trainLine" > /dev/null;
	toStation=$(curl -s https://travelynx.de/api/v1/status/$API_KEY | jq .toStation.name | sed 's/"//' | sed 's/"//')
	echo "$toStation" > /dev/null;
	arrivalTime=$(curl -s https://travelynx.de/api/v1/status/$API_KEY | jq .toStation.scheduledTime)
	echo "$arrivalTime" > /dev/null;	
	actualArrivalTime=$(curl -s https://travelynx.de/api/v1/status/$API_KEY | jq .toStation.realTime)
	echo "$actualArrivalTime" > /dev/null;
	arrivalTimeDate=$(date +%H:%M -d @$arrivalTime)
	actualArrivalTimeDate=$(date +%H:%M -d @$actualArrivalTime)
	
	nextStationTime=$(curl -s https://travelynx.de/api/v1/status/$API_KEY | jq .intermediateStops[].realArrival)
	nextStationName=$(curl -s https://travelynx.de/api/v1/status/$API_KEY | jq .intermediateStops[].name | sed 's/"//' | sed 's/"//')


	SAVEIFS=$IFS
	IFS=$'\n'
	nextStationTime=($nextStationTime)
	nextStationName=($nextStationName)
	IFS=$SAVEIFS

	if [ "$(date +%H:%M)" != "$notificationNextStopTime" ]
	then
		for (( i=0; i<${#nextStationTime[@]}; i++ ))
		do
		
			if [ "$(date +%H:%M)" == "$(date +%H:%M -d @${nextStationTime[$i]})" ] && [ "$NOTIFICATIONS_NEXT_STOP" == "true" ] && [ "$LANGUAGE" == "DE" ]
			then
				notify-send "Nächster Halt:" "${nextStationName[$i]} um $(date +%H:%M -d @${nextStationTime[$i]})" 
				notificationNextStopTime=$(date +%H:%M -d @${nextStationTime[$i]})
			fi

			if [ "$(date +%H:%M)" == "$(date +%H:%M -d @${nextStationTime[$i]})" ] && [ "$NOTIFICATIONS_NEXT_STOP" == "true" ] && [ "$LANGUAGE" == "EN" ]
			then
				notify-send "Next Stop:" "${nextStationName[$i]} at $(date +%H:%M -d @${nextStationTime[$i]})" 
				notificationNextStopTime=$(date +%H:%M -d @${nextStationTime[$i]})
			fi
		done
	fi


	# Checking if Arrival Time changed to send a new Notification
	if [ "$actualArrivalTime" -gt "$notificationLastDelay" ]
	then
		notificationDelaySent="false"
	fi

	# Checking if Arrival Time changed to send a new Notification
	if [ "$actualArrivalTime" != "$notificationLastDelay" ] && [ "$actualArrivalTime" != "$arrivalTime" ]
	then
		notificationDelaySent="false"
	fi

        
        # Sending a Notification if an ICE Train is delayed	
	if [ $isCheckedIn = "true" ] && [ "$actualArrivalTime" -gt "$arrivalTime" ] && [ $notificationDelaySent == "false" ] && [ $trainType == "ICE" ] && [ $NOTIFICATIONS_DELAY == "true" ] && [ $LANGUAGE == "DE" ]
	then
		notificationDelaySent="true"
		notify-send "Zugverspätung:" "Information zu $trainType $trainNo nach $toStation Ankuft heute $actualArrivalTimeDate anstatt $arrivalTimeDate"
	fi

        # Sending a Notification if an ICE Train is delayed	
	if [ $isCheckedIn = "true" ] && [ "$actualArrivalTime" -gt "$arrivalTime" ] && [ $notificationDelaySent == "false" ] && [ $trainType == "ICE" ] && [ $NOTIFICATIONS_DELAY == "true" ] && [ $LANGUAGE == "EN" ]
	then
		notificationDelaySent="true"
		notify-send "Delay:" "Information on $trainType $trainNo to $toStation arrival today $actualArrivalTimeDate instead of $arrivalTimeDate"
	fi

	# Sending a Notification if an IC Train is delayed
	if [ $isCheckedIn = "true" ] && [ "$actualArrivalTime" -gt "$arrivalTime" ] && [ $notificationDelaySent == "false" ] && [ $trainType == "IC" ] && [ $NOTIFICATIONS_DELAY == "true" ] && [ $LANGUAGE == "DE" ]
	then
		notificationDelaySent="true"
		notify-send "Zugverspätung:" "Information zu $trainType $trainNo nach $toStation Ankuft heute $actualArrivalTimeDate anstatt $arrivalTimeDate"
	fi

	# Sending a Notification if an IC Train is delayed
	if [ $isCheckedIn = "true" ] && [ "$actualArrivalTime" -gt "$arrivalTime" ] && [ $notificationDelaySent == "false" ] && [ $trainType == "IC" ] && [ $NOTIFICATIONS_DELAY == "true" ] && [ $LANGUAGE == "EN" ]
	then
		notificationDelaySent="true"
		notify-send "Delay:" "Information on $trainType $trainNo to $toStation arrival today $actualArrivalTimeDate instead of $arrivalTimeDate"
	fi

	# Sending a Notification if other (not ICE/IC) Train is	delayed
	if [ $isCheckedIn = "true" ] && [ "$actualArrivalTime" -gt "$arrivalTime" ] && [ $notificationDelaySent == "false" ] && [ $trainType != "ICE" ] && [ $trainType != "IC" ] && [ $NOTIFICATIONS_DELAY == "true" ] && [ $LANGUAGE == "DE" ] 
	then
		notificationDelaySent="true"
		notify-send "Zugverspätung:" "Information zu $trainType $trainLine nach $toStation Ankuft heute $actualArrivalTimeDate anstatt $arrivalTimeDate"
	fi


	# Sending a Notification if other (not ICE/IC) Train is	delayed
	if [ $isCheckedIn = "true" ] && [ "$actualArrivalTime" -gt "$arrivalTime" ] && [ $notificationDelaySent == "false" ] && [ $trainType != "ICE" ] && [ $trainType != "IC" ] && [ $NOTIFICATIONS_DELAY == "true" ] && [ $LANGUAGE == "EN" ]
	then
		notificationDelaySent="true"
		notify-send "Delay:" "Information on $trainType $trainLine to $toStation arrival today $actualArrivalTimeDate instead of $arrivalTimeDate"
	fi

	# Sending a Notification if the ICE Train is on time again
	if [ "$actualArrivalTime" -eq "$arrivalTime" ] && [ $notificationDelaySent == "true" ] && [ $isCheckedIn == "true" ] && [ $trainType == "ICE" ] && [ $NOTIFICATION_DELAY == "true" ] && [ $LANGUAGE == "DE" ]
	then
		notify-send "Information:" "Information zu $trainType $trainNo nach $toStation ist wieder pünktlich"	
	fi

	# Sending a Notification if the ICE Train is on time again
	if [ "$actualArrivalTime" -eq "$arrivalTime" ] && [ $notificationDelaySent == "true" ] && [ $isCheckedIn == "true" ] && [ $trainType == "ICE" ] && [ $NOTIFICATION_DELAY == "true" ] && [ $LANGUAGE == "EN" ]
	then
		notify-send "Information:" "Information on $trainType $trainNo to $toStation is on time again"	
	fi

	# Sending a Notification if the IC Train is on time again
	if [ "$actualArrivalTime" -eq "$arrivalTime" ] && [ $notificationDelaySent == "true" ] && [ $isCheckedIn == "true" ] && [ $trainType == "IC" ] && [ $NOTIFICATION_DELAY == "true" ] && [ $LANGUAGE == "DE" ]
	then
		notify-send "Information:" "Information zu $trainType $trainNo nach $toStation ist wieder pünktlich"	
	fi

	# Sending a Notification if the IC Train is on time again
	if [ "$actualArrivalTime" -eq "$arrivalTime" ] && [ $notificationDelaySent == "true" ] && [ $isCheckedIn == "true" ] && [ $trainType == "IC" ] && [ $NOTIFICATION_DELAY == "true" ] && [ $LANGUAGE == "EN" ]
	then
		notify-send "Information:" "Information on $trainType $trainNo to $toStation is on time again"	
	fi

	# Sending a Notification if a other (not ICE/IC) Train is on time again
	if [ "$actualArrivalTime" -eq "$arrivalTime" ] && [ $notificationDelaySent == "true" ] && [ $isCheckedIn == "true" ] && [ $trainType != "ICE" ] && [ $trainType != "IC" ] && [ $NOTIFICATION_DELAY = "true" ] && [ $LANGUAGE == "DE" ]
	then
		notify-send "Information:" "Information zu $trainType $trainLine nach $toStation ist wieder pünktlich"	
	fi

	# Sending a Notification if a other (not ICE/IC) Train is on time again
	if [ "$actualArrivalTime" -eq "$arrivalTime" ] && [ $notificationDelaySent == "true" ] && [ $isCheckedIn == "true" ] && [ $trainType != "ICE" ] && [ $trainType != "IC" ] && [ $NOTIFICATION_DELAY = "true" ] && [ $LANGUAGE == "EN" ]
	then
		notify-send "Information:" "Information on $trainType $trainLine ti $toStation is on time again"	
	fi
	
	# Saving the Delay from the latest Notification
	notificationLastDelay=$actualArrivalTime
	
	# Showing the Label for Polybar
	if [ $isCheckedIn == "true" ] && [ $trainType != "ICE" ] && [ $trainType != "IC" ] && [ $LANGUAGE == "DE" ] 
	then
		echo "$SYMBOL" $trainType $trainLine "nach" $toStation
	elif [ $isCheckedIn == "true" ] && [ $trainType != "ICE" ] && [ $trainType != "IC" ] && [ $LANGUAGE == "EN" ]
	then
		echo "$SYMBOL" $trainType $trainLine "to" $toStation
	elif [ $isCheckedIn == "true" ] && [ $trainType == "IC" ] && [ $LANGUAGE == "DE" ]
	then
		echo "$SYMBOL" $trainType $trainNo "nach" $toStation
	elif [ $isCheckedIn == "true" ] && [ $trainType == "IC" ] && [ $LANGUAGE == "EN" ]
	then
	        echo "$SYMBOL" $trainType $trainNo "to" $toStation
	elif [ $isCheckedIn == "true" ] && [ $trainType == "ICE" ] && [ $LANGUAGE == "DE" ]
	then
		echo "$SYMBOL" $trainType $trainNo "nach" $toStation
	elif [ $isCheckedIn == "true" ] && [ $trainType == "ICE" ] && [ $LANGUAGE == "EN" ]
	then
		echo "$SYMBOL" $trainType $trainNo "to" $toStation
	elif [ $isCheckedIn == "false" ] && [ $LANGUAGE == "EN" ]
	then
		echo "$SYMBOL"" not checked in"
                notificationDelaySent="false"
                notificationLastDelay=0
                notificationNextStopSent="true"
	else
		echo "$SYMBOL"" nicht eingecheckt"
		notificationDelaySent="false"
		notificationLastDelay=0
		notificationNextStopSent="true"
		notificationNextStopTime=""
	fi
	sleep $INTERVAL

done
