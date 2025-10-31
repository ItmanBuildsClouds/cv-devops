import json
import boto3
import os

ses = boto3.client('ses')
RECIPIENT_MAIL = os.environ['RECIPIENT_MAIL']

def lambda_handler(event, context):
    for record in event['Records']:
        data = json.loads(record['body'])
        
        name = data['name']
        email = data['email']
        topic = data['topic']
        message = data['message']

        email_body = f"""
        New message received from:
        -------------------------
        Name: {name}
        Email: {email}
        Topic: {topic}
        -------------------------
        Message: {message}
        """

        ses.send_email(
            Source=RECIPIENT_MAIL,
            Destination={
                'ToAddresses': [RECIPIENT_MAIL]
            },
            Message={
                'Subject': {
                    'Data': 'New message from CV DevOps'
                },
                'Body': {
                    'Text': {
                        'Data': email_body
                    }
                }
            }
        )
        print('Email sent')

    return {
        'statusCode': 200,
        'body': json.dumps('Hello from Lambda!')
    }
