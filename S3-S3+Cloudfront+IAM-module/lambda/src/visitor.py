import json
import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table("visitor-count")
COUNTER_ID = "counter"


def lambda_handler(event, context):
    try:
        # Atomic counter increment
        response = table.update_item(
            Key={"id": COUNTER_ID},
            UpdateExpression="SET visitor_count = if_not_exists(visitor_count, :zero) + :inc",
            ExpressionAttributeValues={":inc": 1, ":zero": 0},
            ReturnValues="UPDATED_NEW",
        )

        count = int(response["Attributes"]["visitor_count"])

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",  # Safety net for CORS
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, X-Amz-Date, X-Api-Key",
            },
            "body": json.dumps({"visitor_count": count}),
        }

    except ClientError as e:
        print(f"DynamoDB Error: {e.response['Error']['Message']}")
        return {
            "statusCode": 500,
            "headers": {
                "Access-Control-Allow-Origin": "*",
                "Content-Type": "application/json",
            },
            "body": json.dumps({"error": "Failed to update visitor count"}),
        }

    except Exception as e:
        print(f"Unexpected Error: {str(e)}")
        return {
            "statusCode": 500,
            "headers": {
                "Access-Control-Allow-Origin": "*",
                "Content-Type": "application/json",
            },
            "body": json.dumps({"error": "Internal server error"}),
        }
