def lambda_handler(event, context):
    print(event)
    print("Lambda got triggered!")
    
    return {
        "statusCode": 200,
        "body": "Hello from Lambda!"
    }