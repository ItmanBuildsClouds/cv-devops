import boto3
import json


MODEL_ID = "anthropic.claude-3-haiku-20240307-v1:0"
REGION = "eu-central-1"
PROMPT = """
Jesteś asystentem AI odpowiadającym na pytania o Piotra Itman - specjaliście DevOps i AWS.

INFORMACJE O PIOTRZE ITMAN:
- Specjalista DevOps i Cloud Engineer
- Ekspert AWS z certyfikatami
- Doświadczenie w Terraform, Docker, Kubernetes
- Programuje w Python, Bash, JavaScript
- Pracuje z CI/CD, Jenkins, GitLab
- Specjalizuje się w automatyzacji infrastruktury
- Lokalizacja: Polska
- Pasjonuje się nowymi technologiami cloud

Odpowiadaj profesjonalnie i szczegółowo na pytania o jego umiejętności, doświadczenie i projekty. Jeśli nie masz konkretnej informacji, napisz "Nie mam tej szczegółowej informacji o Piotrze".

"""

bedrock = boto3.client("bedrock-runtime", region_name="eu-central-1")

def invoke_model(client, model_id, prompt):

    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 384,
        "temperature": 0.5
    }
    response = client.invoke_model(
        modelId=model_id,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(body)
    )

    result = json.loads(response["body"].read())

    return result["content"][0]["text"]

def lambda_handler(event, context):
    cors_headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization,Origin,Accept',
        'Access-Control-Allow-Methods': 'POST,OPTIONS',
        'Content-Type': 'application/json'
    }
    try:
        user_question = json.loads(event['body'])['message']
        system_prompt = PROMPT
        full_prompt = f"{system_prompt}\n\nQuestion: {user_question}"
        ai_response = invoke_model(bedrock, MODEL_ID, full_prompt)

        return {
            'statusCode': 200,
            'headers': cors_headers,
            'body': json.dumps({'response': ai_response})
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'headers': cors_headers,
            'body': json.dumps({'error': str(e)})
        }


