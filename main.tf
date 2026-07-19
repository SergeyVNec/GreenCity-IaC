provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

# Latest Amazon Linux 2023 AMI for this region — portable across accounts/regions.
# var.ami_id overrides it if set.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.al2023.id
}

module "network" {
  source             = "./modules/network"
  project_name       = var.project_name
  availability_zones = var.availability_zones
}

module "ecr" {
  source           = "./modules/ecr"
  project_name     = var.project_name
  repository_names = var.ecr_repositories
}

module "security" {
  source       = "./modules/security"
  project_name = var.project_name
  vpc_id       = module.network.vpc_id
}

module "rds" {
  source                 = "./modules/rds"
  project_name           = var.project_name
  subnet_ids             = module.network.public_subnet_ids
  vpc_security_group_ids = [module.security.rds_sg_id]
}

module "iam" {
  source        = "./modules/iam"
  project_name  = var.project_name
  db_secret_arn = module.rds.master_user_secret_arn
}

module "app" {
  source                = "./modules/ec2"
  project_name          = var.project_name
  ami_id                = local.ami_id
  instance_type         = var.app_instance_type
  subnet_id             = module.network.public_subnet_ids[0] # first AZ
  security_group_ids    = [module.security.app_sg_id]
  instance_profile_name = module.iam.instance_profile_name
  ecr_registry          = module.ecr.registry_url
  region                = var.region
}

module "codebuild" {
  source           = "./modules/codebuild"
  project_name     = var.project_name
  region           = var.region
  ecr_registry     = module.ecr.registry_url
  frontend_api_url = var.frontend_api_url != "" ? var.frontend_api_url : module.alb.alb_dns_name
  google_client_id = var.google_client_id
}

module "alb" {
  source           = "./modules/alb"
  project_name     = var.project_name
  vpc_id           = module.network.vpc_id
  subnet_ids       = module.network.public_subnet_ids
  alb_sg_id        = module.security.alb_sg_id
  app_instance_ids = [module.app.instance_id]
}

module "deploy" {
  source        = "./modules/deploy"
  project_name  = var.project_name
  region        = var.region
  ecr_registry  = module.ecr.registry_url
  db_host       = module.rds.endpoint
  db_name       = module.rds.db_name
  db_user       = module.rds.username
  db_secret_arn = module.rds.master_user_secret_arn
}

module "jenkins" {
  source            = "./modules/jenkins"
  project_name      = var.project_name
  region            = var.region
  ami_id            = local.ami_id
  vpc_id            = module.network.vpc_id
  subnet_id         = module.network.public_subnet_ids[0]
  codebuild_project = module.codebuild.project_name
  deploy_document   = module.deploy.document_name
  app_instance_id   = module.app.instance_id
  discord_webhook   = var.discord_webhook
  jenkins_repos = [
    { name = "backcore", url = "https://github.com/GreenCity-UA-4823-4826/GreenCityMVP.git", branch = "dev_java21" },
    { name = "backuser", url = "https://github.com/GreenCity-UA-4823-4826/GreenCityUser.git", branch = "dev" },
    { name = "frontend", url = "https://github.com/GreenCity-UA-4823-4826/GreenCity-Client.git", branch = "dev-react" },
  ]
}

module "monitoring" {
  source          = "./modules/monitoring"
  project_name    = var.project_name
  region          = var.region
  app_instance_id = module.app.instance_id
  alarm_email     = var.alarm_email
}

module "k3s" {
  source        = "./modules/k3s"
  project_name  = var.project_name
  region        = var.region
  ami_id        = local.ami_id
  vpc_id        = module.network.vpc_id
  subnet_id     = module.network.public_subnet_ids[0]
  ecr_registry  = module.ecr.registry_url
  db_secret_arn = module.rds.master_user_secret_arn
  agent_count   = 2
}

# Let k3s pods reach RDS (the RDS SG otherwise only allows the app SG)
resource "aws_security_group_rule" "k3s_to_rds" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = module.security.rds_sg_id
  source_security_group_id = module.k3s.sg_id
  description              = "PostgreSQL from k3s pods"
}
