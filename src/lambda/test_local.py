import json
from chatbot_bedrock import lambda_handler

# Test event (symuluje API Gateway)
test_event = {
    'body': json.dumps({'message': 'Kim jesteś?'})
}

# Wywołaj funkcję
result = lambda_handler(test_event, None)
print("Status:", result['statusCode'])
print("Response:", json.loads(result['body']))