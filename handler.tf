data "aws_ssm_parameter" "current_nlb_id" {
  name = var.current_nlb_id_param_name
}

module "k3s-nlb-interruption-handler" {
  source              = "git::https://github.com/PiotrKuligowski/terraform-aws-spot-k3s-nlb-interruption-handler.git"
  function_name       = "${var.project}-nlb-interruption-handler"
  component           = "nlb-interruption-handler"
  project             = var.project
  environment_vars    = local.nlb_interruption_handler_env_variables
  policy_statements   = local.nlb_interruption_handler_policy_statements
  eventbridge_trigger = local.spot_interruption_event_pattern
  tags                = var.tags
}

locals {
  nlb_interruption_handler_env_variables = {
    REGION                    = data.aws_region.current.name
    PROJECT                   = var.project
    CURRENT_NLB_ID_PARAM_NAME = var.current_nlb_id_param_name
  }

  spot_interruption_event_pattern = <<PATTERN
{
  "detail-type": ["EC2 Spot Instance Interruption Warning"],
  "source": ["aws.ec2"]
}
  PATTERN

  nlb_interruption_handler_policy_statements = {
    AllowAttachAndDescribe = {
      effect = "Allow",
      actions = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DetachInstances",
        "ssm:ListCommandInvocations",
        "ec2:DescribeInstances",
        "ec2:TerminateInstances"
      ]
      resources = ["*"]
    }

    AllowLogs = {
      effect    = "Allow",
      actions   = ["logs:*"]
      resources = ["arn:aws:logs:*:*:*"]
    }

    AllowSSM = {
      effect    = "Allow",
      actions   = ["ssm:GetParameter"]
      resources = [data.aws_ssm_parameter.current_nlb_id.arn]
    }
  }
}