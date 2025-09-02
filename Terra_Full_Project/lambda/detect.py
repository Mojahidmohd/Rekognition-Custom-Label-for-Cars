import json
import boto3
import base64
import uuid
import time
from decimal import Decimal
import os

# Environment variables injected by Terraform
DDB_TABLE_NAME = os.environ["DDB_TABLE"]
PROJECT_ARN = os.environ["PROJECT_VERSION_ARN"]
REGION = os.environ.get("REGION", "us-east-1")

# Initialize clients
dynamodb = boto3.resource("dynamodb", region_name=REGION)
rekognition = boto3.client("rekognition", region_name=REGION)
table = dynamodb.Table(DDB_TABLE_NAME)

# Convert floats to Decimal recursively for DynamoDB
def to_decimal(obj):
    if isinstance(obj, list):
        return [to_decimal(i) for i in obj]
    elif isinstance(obj, dict):
        return {k: to_decimal(v) for k, v in obj.items()}
    elif isinstance(obj, float):
        return Decimal(str(obj))
    else:
        return obj

# Convert Decimal back to float for JSON response
def decimal_to_float(obj):
    if isinstance(obj, list):
        return [decimal_to_float(i) for i in obj]
    elif isinstance(obj, dict):
        return {k: decimal_to_float(v) for k, v in obj.items()}
    elif isinstance(obj, Decimal):
        return float(obj)
    else:
        return obj

def lambda_handler(event, context):
    headers = {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Allow-Methods": "OPTIONS,POST,GET"
    }

    # Handle preflight request
    if event.get("httpMethod") == "OPTIONS":
        return {"statusCode": 200, "headers": headers, "body": ""}

    try:
        # Parse body
        body = event.get("body", "{}")
        if isinstance(body, str):
            body = json.loads(body)

        image_b64 = body.get("image")
        meta = body.get("meta", {})

        if not image_b64:
            return {"statusCode": 400, "headers": headers,
                    "body": json.dumps({"error": "Missing 'image' field"})}

        # Generate ID and timestamp
        item_id = str(uuid.uuid4())
        timestamp = Decimal(str(time.time()))

        # Step 1: Store image immediately in DynamoDB with empty Rekognition
        item = {
            "id": item_id,
            "timestamp": timestamp,
            "image": image_b64,
            "meta": meta,
            "rekognition": {}  # empty initially
        }
        table.put_item(Item=item)

        # Step 2: Decode image for Rekognition
        image_bytes = base64.b64decode(image_b64 + "=" * (-len(image_b64) % 4))

        # Step 3: Call Rekognition Custom Labels
        try:
            rek_resp = rekognition.detect_custom_labels(
                ProjectVersionArn=PROJECT_ARN,
                Image={"Bytes": image_bytes},
                MaxResults=10
            )
        except rekognition.exceptions.InvalidImageFormatException:
            rek_resp = {"CustomLabels": []}

        # Step 4: Update DynamoDB item by overwriting it
        item["rekognition"] = to_decimal(rek_resp)
        table.put_item(Item=item)  # overwrite the same item

        # Step 5: Return JSON to browser
        response_body = {
            "message": "Image analyzed & stored successfully",
            "id": item_id,
            "labels": decimal_to_float(rek_resp.get("CustomLabels", []))
        }

        return {"statusCode": 200, "headers": headers, "body": json.dumps(response_body)}

    except Exception as e:
        return {"statusCode": 500, "headers": headers,
                "body": json.dumps({"error": str(e)})}
