#!/bin/sh

export EMAIL_SENDER_TRANSPORT=SMTP
# [INFO] You can set any of the attributes found here:
# https://metacpan.org/pod/Email::Sender::Transport::SMTP#ATTRIBUTES
# For example, the following lines set the attributes host and port
export EMAIL_SENDER_TRANSPORT_host=smtp.example.com
export EMAIL_SENDER_TRANSPORT_port=25
