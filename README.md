# Salesforce DX Project: Next Steps

Now that you’ve created a Salesforce DX project, what’s next? Here are some documentation resources to get you started.

## How Do You Plan to Deploy Your Changes?

Do you want to deploy a set of changes, or create a self-contained application? Choose a [development model](https://developer.salesforce.com/tools/vscode/en/user-guide/development-models).

## Configure Your Salesforce DX Project

The `sfdx-project.json` file contains useful configuration information for your project. See [Salesforce DX Project Configuration](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_ws_config.htm) in the _Salesforce DX Developer Guide_ for details about this file.

## Read All About It

- [Salesforce Extensions Documentation](https://developer.salesforce.com/tools/vscode/)
- [Salesforce CLI Setup Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_intro.htm)
- [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_intro.htm)
- [Salesforce CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/cli_reference.htm)

## Create Unlocked Package 

sf config set target-dev-hub order-management

sf package create --name "Project Tracker App" --package-type Unlocked --path  "force-app" --target-dev-hub order-management --error-notification-username amitsingh536@agentforce.com

sf package version create --package "Project Tracker App" --installation-key "AMITDEVOPS2026" --definition-file config/project-scratch-def.json --code-coverage --wait 10

https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgK000000ArCjQAK

https://test.salesforce.com/packaging/installPackage.apexp?p0=04tgK000000ArCjQAK


<domain_name>.lightning.force.com/packaging/installPackage.apexp?p0=04tgK000000ArCjQAK