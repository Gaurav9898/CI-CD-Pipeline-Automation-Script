#!/bin/bash

containers="$(docker ps --format "{{.Names}}")"$'\n';
containers+="$(docker ps -f "status=exited" --format "{{.Names}}")";
arrIndex=0
isSendMail=0
csvFileName="containerstatus.csv"
dockerGateway=172.17.0.1
isHeaderAdded=0
mailContent="mailContent.txt"
logFiles=""
mailTableBody=""

printf "name,status\n" > "$csvFileName"

for container in $containers
do
        port=$(docker port $container | head -n1 | cut -d':' -f2)
        protocol=$(docker port $container | head -n1 | cut -d'/' -f2 | cut -d'-' -f1 | xargs echo -n)
        if [[ -z $port ]]
        then            
                containerStatus=$(docker inspect -f '{{.State.Status}}' $container);
                if [[ $containerStatus != "running" ]]
                then 
                        statusCode=1
                fi
        else 
                if [[ $protocol == "udp" ]]
                then
                        nc -zu $dockerGateway $port
                else
                        nc -z $dockerGateway $port
                fi
                statusCode=$?
        fi

        if [[ $statusCode != 0 ]]
        then    
                isSendMail=1
                docker logs $container >& "${container}_logs.txt"
                logFiles+="${container}_logs.txt "
                docker restart $container                
                restartStatus=$?
                containerStatus=$(docker inspect -f '{{.State.Status}}' $container);
                printf "$container,$([ $restartStatus == 0 ] && [ $containerStatus == "running" ] && echo "Container restarted successfully" || echo "Container not restarted successfully")\n" >> "$csvFileName"
                mailTableBody+="
                        <tr>
                          <td>${container}</td>
                          <td>$([ $restartStatus == 0 ] && [ $containerStatus == "running" ] && echo "Container restarted successfully" || echo "Container not restarted successfully")</td>
                        <tr>
                        "
        fi
done

function add_file {
    echo "--MULTIPART-MIXED-BOUNDARY
Content-Type: $1
Content-Transfer-Encoding: base64" >> "$mailContent"

    if [ ! -z "$2" ]; then
        echo "Content-Disposition: inline
Content-Id: <$2>" >> "$mailContent"
    else
        echo "Content-Disposition: attachment; filename=$4" >> "$mailContent"
    fi
    echo "
$3
" >> "$mailContent"
}

if [[ $isSendMail == 1 ]]
then
        smtpUrl="smtp://smtp.zeptomail.in:587"
        smtpFrom="helpdesk@relipay.net"
        smtpTo="bms@reliablesoft.co.in"
        smtpCc1="prakash.choudhary@reliablesoft.co.in"
        smtpCc2="sayam.jain@reliablesoft.co.in"
        smtpCredentials="helpdesk@relipay.net:<place auth token here>"
        mailFileName="mail.txt"
        mailSubject="Monitoring"

        cat /dev/null > $mailFileName

        # html message to send
        echo "<html>
                <head>
                   <style>
                      table,
                      th,
                      td {
                        border: 1px solid black;
                        border-collapse: collapse;
                      }
                      th,
                      td {
                        padding: 5px 10px;
                      }
                    </style>
                </head>
                <body>
                    <div>
                        <p>Please find attached file for details of downed containers.</p>                      
                    </div>
                    <table>
                        <tr>
                          <th>Container Name</th>
                          <th>Status</th>
                        </tr>
                        ${mailTableBody}
                      </table>
                </body>
                </html>" > mailBody.html

        mailBodyBase64=$(cat mailBody.html | base64)

        echo "From: <$smtpFrom>
To: <$smtpTo>
Subject: $mailSubject
Reply-To: <$smtpFrom>
Cc: <$smtpCc1>, <$smtpCc2>
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary=\"MULTIPART-MIXED-BOUNDARY\"

--MULTIPART-MIXED-BOUNDARY
Content-Type: multipart/alternative; boundary=\"MULTIPART-ALTERNATIVE-BOUNDARY\"

--MULTIPART-ALTERNATIVE-BOUNDARY
Content-Type: text/html; charset=utf-8
Content-Transfer-Encoding: base64
Content-Disposition: inline

$mailBodyBase64

--MULTIPART-ALTERNATIVE-BOUNDARY--
" > "$mailContent"

        csvBase64=$(cat $csvFileName | base64)
        add_file "text/csv" "" "$csvBase64" "$csvFileName"

        for logFile in $logFiles
        do
                logBase64=$(cat $logFile | base64)
                add_file "text/plain" "" "$logBase64" "$logFile"
        done

        echo "--MULTIPART-MIXED-BOUNDARY--" >> "$mailContent"

        curl -v -s "$smtpUrl" \
             --mail-from "$smtpFrom" \
             --mail-rcpt "$smtpTo" \
             --mail-rcpt "$smtpCc1" \
             --mail-rcpt "$smtpCc2" \
             --ssl -u "$smtpCredentials" \
             -T "$mailContent" -k --anyauth
        mailRes=$?

        if [[ $mailRes != 0 ]]
        then
                echo "Mail sending failed with $mailRes"
        else
                echo "Mail sent successfully"
        fi
fi

#rm *.txt *.html *.csv
