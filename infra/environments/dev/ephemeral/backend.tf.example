# Copy to backend.tf and replace 028708951757 with your AWS account id.
# Run once:
#   cp backend.tf.example backend.tf
#   sed -i 's/028708951757/<YOUR_ACCOUNT_ID>/' backend.tf
#   terraform init
#
terraform {
  backend "s3" {
    bucket         = "llm-chat-tfstate-028708951757"
    key            = "mlops/llm-chat/dev/ephemeral.tfstate"
    region         = "us-west-2"
    dynamodb_table = "llm-chat-tflock"
    encrypt        = true
  }
}
