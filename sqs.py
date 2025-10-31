import json
import boto3
import os
from datetime import datetime

sqs = boto3.client('sqs')
SQS_QUEUE_URL = os.environ['SQS_QUEUE_URL']

def lambda_handler(event, context):
    print(f"Event: {json.dumps(event)}")
    print(f"Queue URL: {SQS_QUEUE_URL}")

    try:
        body = json.loads(event['body'])
        response = sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(body)
        )

        return {
            'statusCode': 200,
            'body': json.dumps('API sent to SQS')
        }
    except Exception as e:
        print(f"Error: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps('Error sending API to SQS')
        }

