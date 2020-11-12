terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.32.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=2.3.0"
    }
  }
   required_version = ">=0.13.3"
}

provider "azurerm" {
  features {}
}

data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

data "azurerm_subscription" "current" {
}

resource "random_string" "random" {
  length  = 12
  upper   = false
  special = false
}

module "subscription" {
  source = "github.com/Azure-Terraform/terraform-azurerm-subscription-data.git?ref=v1.0.0"
  subscription_id = data.azurerm_subscription.current.subscription_id
}

module "rules" {
  source = "git@github.com:openrba/python-azure-naming.git?ref=tf"
}

module "metadata" {
  source = "github.com/Azure-Terraform/terraform-azurerm-metadata.git?ref=v1.1.0"

  naming_rules = module.rules.yaml

  market              = "us"
  project             = "https://gitlab.ins.risk.regn.net/example/"
  location            = "useast2"
  sre_team            = "iog-core-services"
  environment         = "sandbox"
  product_name        = random_string.random.result
  business_unit       = "iog"
  product_group       = "core"
  subscription_id     = module.subscription.output.subscription_id
  subscription_type   = "nonprod"
  resource_group_type = "app"
}

module "resource_group" {
  source = "github.com/Azure-Terraform/terraform-azurerm-resource-group.git?ref=v1.0.0"

  location = module.metadata.location
  names    = module.metadata.names
  tags     = module.metadata.tags
}

module "virtual_network" {
  source = "github.com/Azure-Terraform/terraform-azurerm-virtual-network.git?ref=v2.2.0"

  naming_rules = module.rules.yaml

  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  names               = module.metadata.names
  tags                = module.metadata.tags

  address_space = ["10.1.1.0/24"]

  subnets = {
    "iaas-outbound" = { cidrs             = ["10.1.1.0/27"]
                        service_endpoints = ["Microsoft.Sql"] }
  }
}

# create storage account for diagnostic setting
module "create-storage-account" {
    depends_on = [module.resource_group]
    source = "git@github.com:openrba/terraform-azurerm-storage-account.git"
    names                    = module.metadata.names
    location                 = module.metadata.location
    account_kind             = "BlobStorage"
    account_tier             = "Standard"
    replication_type         = "LRS"
    access_tier              = "Cool"
    allow_blob_public_access = false
    authorized_subnets       = {"my_ip" = chomp(data.http.my_ip.body)}
    tags                     = module.metadata.tags
    retention_days           = 7
}

module "mysql" {
  source = "github.com/openrba/terraform-azurerm-mysql-server.git?ref=v0.1.1"

  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  names               = module.metadata.names
  tags                = module.metadata.tags

  server_id = random_string.random.result

  service_endpoints = {"env1" = module.virtual_network.subnet["iaas-outbound"].id}
  access_list = {"home" = {start_ip_address = chomp(data.http.my_ip.body), end_ip_address = chomp(data.http.my_ip.body)}}
  databases = { "foo" = {}
                "bar" = {charset = "utf16", collation = "utf16_general_ci" } }
  # diagnostic storage settings
  mysqlslowlogs         = 20
  mysqlauditlogs        = 10
  ds_allmetrics_rentention_days = 11
  storage_endpoint      = module.create-storage-account.storage_account_name
  storage_account_resource_group = module.resource_group.name
}

module "mysql_replica" {
  source = "github.com/openrba/terraform-azurerm-mysql-server.git?ref=v0.1.1"

  location            = "centralus"
  resource_group_name = module.resource_group.name
  names               = module.metadata.names
  tags                = module.metadata.tags
  
  # to identify replica from primary
  server_id = "Replica"
  
  # this will create the replica
  create_mode               = "Replica"
  creation_source_server_id = module.mysql.id
}

output "resource_group" {
  value = module.resource_group.name
}

output "mysql_fqdn" {
  value = module.mysql.fqdn
}

output "mysql_admin_login" {
  value = module.mysql.administrator_login
}

output "mysql_admin_password" {
  value = module.mysql.administrator_password
}

output "mysql_test_command" {
  value = "mysql -h ${module.mysql.fqdn} -u ${module.mysql.administrator_login}@${module.mysql.name} -p${module.mysql.administrator_password}"
}
