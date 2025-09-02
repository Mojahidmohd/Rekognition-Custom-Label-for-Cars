
output "dynamodb_table" {
  value = aws_dynamodb_table.detections.name
}

output "web_url" {
  value = "http://${aws_instance.web_server.public_ip}"
}
