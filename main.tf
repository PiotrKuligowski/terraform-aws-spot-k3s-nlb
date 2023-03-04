data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_route53_zone" "public" {
  name = var.routes_config.domain
}

module "nlb" {
  source            = "git::https://github.com/PiotrKuligowski/terraform-aws-spot-asg.git"
  ami_id            = var.ami_id
  ssh_key_name      = var.ssh_key_name
  subnet_ids        = var.subnet_ids
  vpc_id            = var.vpc_id
  user_data         = local.nlb_user_data
  policy_statements = local.required_policy
  project           = var.project
  component         = var.component
  tags              = var.tags
  instance_type     = var.instance_type
  security_groups   = var.security_groups
}

locals {
  required_policy = merge({
    AllowGetParameter = {
      effect = "Allow"
      actions = [
        "ssm:GetParameter"
      ]
      resources = [
        "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/*"
      ]
    }
    AllowPutParameter = {
      effect = "Allow"
      actions = [
        "ssm:PutParameter"
      ]
      resources = [
        "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.current_nlb_id_param_name}"
      ]
    }
    allow1 = {
      effect = "Allow",
      actions = [
        "ec2:DescribeInstances",
        "route53:ChangeResourceRecordSets"
      ]
      resources = ["*"]
    }
  }, var.policy_statements)

  nlb_user_data = join("\n", [
    local.user_data_initial,
    local.user_data_update_nginx_config,
    local.user_data_update_dns,
    local.user_data_put_new_nlb_id_to_ssm
  ])

  user_data_initial = <<-EOT
#!/bin/bash -xe
ufw disable
rm -f /etc/nginx/nginx.conf
rm -f /etc/nginx/sites-enabled/default
EOT

  user_data_update_nginx_config = <<-EOT
# Waiting max 15s x 12 = 180s = 3mins for master id to be set by master
retries=0;
while [[ "$(aws ssm get-parameter --name ${var.current_master_id_param_name} --region=${data.aws_region.current.name} --output text --query Parameter.Value | grep -c 'default')" -eq "1" ]]; do
    sleep 15;
    ((retries+=1));
    if [ $retries -eq 12 ]; then
        break
    fi
done

MASTER_ID=$(aws ssm get-parameter --name ${var.current_master_id_param_name} --region=${data.aws_region.current.name} --output text --query Parameter.Value)
MASTER_PRIVATE_IP=$(aws ec2 describe-instances --region=${data.aws_region.current.name} --instance-ids $MASTER_ID --output text --query 'Reservations[*].Instances[*].[PrivateIpAddress]')

echo "
worker_processes 1;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
	worker_connections 768;
}

stream {
    map \$ssl_preread_server_name \$name {
      %{for prefix, port in var.routes_config.routes~}
      ${prefix}.${var.routes_config.domain} ${prefix};
      %{endfor~}
    }

    %{for prefix, port in var.routes_config.routes~}
    upstream ${prefix} {
      server $MASTER_PRIVATE_IP:${port};
    }
    %{endfor~}

    server {
      listen 443;
      proxy_timeout 20s;
      proxy_pass \$name;
      ssl_preread on;
    }
}
" | tee /etc/nginx/nginx.conf

sudo systemctl restart nginx
EOT

  user_data_update_dns = <<-EOT
public_ip=$(curl --silent http://169.254.169.254/latest/meta-data/public-ipv4)
cat > /tmp/r53_update.json <<CONF
{
  "Changes": [
    %{for prefix, port in var.routes_config.routes~}
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${prefix}.${var.routes_config.domain}",
        "Type": "A",
        "TTL": ${var.record_ttl},
        "ResourceRecords": [{"Value":"$public_ip"}]
      }
    },
    %{endfor~}
  ]
}
CONF

# This removes trailing comma at the end of the list
json=$(cat /tmp/r53_update.json)
python3 -c "import json; print(json.dumps($json))" > /tmp/r53_update_clean.json

aws route53 change-resource-record-sets \
  --hosted-zone-id "${data.aws_route53_zone.public.id}" \
  --change-batch file:///tmp/r53_update_clean.json

rm /tmp/r53_update.json
rm /tmp/r53_update_clean.json
EOT

  user_data_put_new_nlb_id_to_ssm = <<-EOT
INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
aws ssm put-parameter \
  --name ${var.current_nlb_id_param_name} \
  --value "$INSTANCE_ID" \
  --overwrite
EOT
}