#!/bin/sh
if [ "$#" -ne 1 ];  then
  echo "Usage: $0  slack_url" >&1
  exit 1
fi

echo "Please Login to OCP using oc login ..... "  
echo "Make sure Openshift Pipeline Operator is installed"
echo "Make sure oc and tkn commands are installed"
echo "Slack url: $1"
echo "Press [Enter] key to resume..." 
read

echo "Create Required Projects … dev and cicd" 
oc new-project dev
oc new-project cicd 

echo "Make sure Openshift Pipeline & GitOps Operators are installed"
echo "Press [Enter] key to resume..."
read
echo "Create Tekton Pipeline for the dotnet app ..."

oc project cicd
oc apply -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/dotnet-sonarqube-scanner-with-login-param.yaml -n cicd
oc apply -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/dotnet-test.yaml -n cicd
oc apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/send-to-webhook-slack/0.1/send-to-webhook-slack.yaml -n cicd
oc policy add-role-to-user edit system:serviceaccount:cicd:pipeline -n dev

echo "kind: Secret
apiVersion: v1
metadata:
  name: webhook-secret
  namespace:  cicd
stringData:
  url: $1" | oc create -f -

oc policy add-role-to-user edit system:serviceaccount:cicd:pipeline -n openshift-gitops
oc policy add-role-to-user edit system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller -n dev
oc apply -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/tekton-gitops.yaml -n cicd


echo "Make sure tkn command line tool is available in your command prompt"
echo "Press [Enter] key to resume..."
read
echo "Running Tekton GitOps pipeline for dotnet core app …"
tkn pipeline start dotnet-gitops-pipeline --param slack_enabled=true --param project-name=dev --workspace name=dotnet-workspace,volumeClaimTemplateFile=https://raw.githubusercontent.com/openshift/pipelines-tutorial/pipelines-1.5/01_pipeline/03_persistent_volume_claim.yaml -n cicd

echo "Done!!"
