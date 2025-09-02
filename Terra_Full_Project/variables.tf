variable "env" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "<Your-Region>"
}

variable "rekognition_model_arn" {
  description = "ARN of the Rekognition Custom Labels Project Version"
  type        = string
  default     = "<Your-ARN>"
}




