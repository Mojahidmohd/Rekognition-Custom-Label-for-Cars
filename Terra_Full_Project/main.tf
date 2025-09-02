
########################################
# DynamoDB Table
########################################
resource "aws_dynamodb_table" "detections" {
  name         = "CarDetections-${var.env}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  range_key    = "timestamp"

  attribute { 
    name = "id"
    type = "S" 
  }
  attribute { 
    name = "timestamp"
    type = "N" 
  }
}

########################################
# IAM Role for Lambda
########################################
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "rekognition-lambda-role-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "rekognition-lambda-policy-${var.env}"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["rekognition:DetectCustomLabels"],
        Resource = var.rekognition_model_arn
      },
      {
        Effect   = "Allow",
        Action   = ["dynamodb:PutItem","dynamodb:Scan","dynamodb:Query","dynamodb:GetItem"],
        Resource = aws_dynamodb_table.detections.arn
      },
      {
        Effect   = "Allow",
        Action   = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

########################################
# Lambda Function
########################################
resource "aws_lambda_function" "rekognition_lambda" {
  function_name    = "rekognition-detect-car-${var.env}"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "detect.lambda_handler"
  runtime          = "python3.13"
  filename         = "lambda/detect.zip"
  source_code_hash = filebase64sha256("lambda/detect.zip")

    depends_on = [
    aws_dynamodb_table.detections
  ]

  environment {
    variables = {
      DDB_TABLE           = aws_dynamodb_table.detections.name
      PROJECT_VERSION_ARN = var.rekognition_model_arn
      REGION              = var.aws_region
    }
  }
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rekognition_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*/*"
}

########################################
# API Gateway REST API with CORS
########################################
resource "aws_api_gateway_rest_api" "rest_api" {
  name        = "rekognition-rest-api-${var.env}"
  description = "REST API for Car Detection"
}

resource "aws_api_gateway_resource" "detect_resource" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "detect"
}

resource "aws_api_gateway_method" "post_detect" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.detect_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  resource_id             = aws_api_gateway_resource.detect_resource.id
  http_method             = aws_api_gateway_method.post_detect.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.rekognition_lambda.invoke_arn
}

# OPTIONS /detect for CORS
resource "aws_api_gateway_method" "options_detect" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.detect_resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_integration" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.detect_resource.id
  http_method = aws_api_gateway_method.options_detect.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }

  passthrough_behavior = "WHEN_NO_MATCH"
}

resource "aws_api_gateway_method_response" "options_response" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.detect_resource.id
  http_method = aws_api_gateway_method.options_detect.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.detect_resource.id
  http_method = aws_api_gateway_method.options_detect.http_method
  status_code = aws_api_gateway_method_response.options_response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  response_templates = {
    "application/json" = ""
  }
}

# Deployment + Stage
resource "aws_api_gateway_deployment" "deployment" {
  depends_on  = [
    aws_api_gateway_integration.lambda_integration,
    aws_api_gateway_integration_response.options_integration_response
  ]
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
}

resource "aws_api_gateway_stage" "api_stage" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  deployment_id = aws_api_gateway_deployment.deployment.id
  stage_name    = var.env
}

########################################
# VPC & Networking
########################################
resource "aws_vpc" "web_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.web_vpc.id
}

data "aws_availability_zones" "available" {}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.web_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.web_vpc.id
  route { 
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

########################################
# Security Group
########################################
resource "aws_security_group" "web_sg" {
  name   = "web-sg"
  vpc_id = aws_vpc.web_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

########################################
# IAM Role for EC2
########################################
resource "aws_iam_role" "ec2_role" {
  name = "ec2-basic-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
        {
            Action = "sts:AssumeRole"
            Effect = "Allow"
            Principal = { Service = "ec2.amazonaws.com" }
        }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-basic-profile"
  role = aws_iam_role.ec2_role.name
}

# Construct API URL once
locals {
  backend_url = "https://${aws_api_gateway_rest_api.rest_api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.api_stage.stage_name}"
}

########################################
# EC2 Instance (t2.micro)
########################################
resource "aws_instance" "web_server" {
  ami                         = "ami-00ca32bbc84273381" # Amazon Linux 2023 us-east-1
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

# Inject into user_data.sh
user_data = templatefile("${path.module}/user_data.sh", {
  BACKEND_URL = local.backend_url
  INDEX_ZIP   = filebase64("${path.module}/index.zip")
})

  depends_on = [
    aws_api_gateway_stage.api_stage,
    aws_api_gateway_deployment.deployment
  ]

  tags = { Name = "ec2-webserver" }
}
