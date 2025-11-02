def test_import():
    import chatbot_bedrock
    assert chatbot_bedrock is not None

def test_lambda_handler_exists():
    from chatbot_bedrock import lambda_handler
    assert callable(lambda_handler)