# Openshift CI/CD for simple DotNet Application

This Project Handle the basic CI/CD of DotNet application 

To run locally with DotNet installed:   

```
dotnet test Tests --logger trx 
dotnet build
dotnet run
```

To deploy the application directly into Openshift using s2i you can use the folloing:
```
oc new-app --name=mydotnet dotnet~https://github.com/osa-ora/simple_dotnet
oc expose svc/mydotnet
```

Note that as we have more than one project in this repository (application and test project), we have added .s2i/environment file which point to the application that we need to deploy into Openshift using s2i. 
```
DOTNET_STARTUP_PROJECT=sample_app/sample.csproj
```

To use Jenkins on Openshift for CI/CD, first we need to build DotNet Jenkins Slave template to use in our CI/CD 

## 1) Build The Environment

Run the following commands to build the environment and provision Jenkins and its slaves templates:  

```
oc new-project cicd //this is the project for cicd

oc process -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/bc_jenkins_slave_template.yaml -n cicd | oc create -f -
oc start-build bc/dotnet-jenkins-slave
oc logs bc/dotnet-jenkins-slave -f

oc new-app jenkins-persistent  -p MEMORY_LIMIT=2Gi  -p VOLUME_CAPACITY=4Gi -n cicd

oc new-project dev //this is project for application development
oc policy add-role-to-user edit system:serviceaccount:cicd:default -n dev
oc policy add-role-to-user edit system:serviceaccount:cicd:jenkins -n dev

```


## 2) Configure Jenkins 
In case you completed 1st step, it will auto-detect the slave dotnet image based on the label and annotation and no thing need to be done to configure it.
```
    labels:
      role: jenkins-slave
    annotations:
      role: jenkins-slave 
```
Otherwise you can do it manually as following:  

From inside Jenkins --> go to Manage Jenkins ==> Configure Jenkins then scroll to cloud section:
https://{JENKINS_URL}/configureClouds
Now click on Pod Templates, add new one with name "dotnet-jenkins-dotnet", label "dotnet-jenkins-slave", container template name "jnlp", docker image "image-registry.openshift-image-registry.svc:5000/cicd/jenkins-dotnet-slave" 

See the picture:
<img width="1242" alt="Screen Shot 2021-01-04 at 12 09 05" src="https://user-images.githubusercontent.com/18471537/103524212-d2d93800-4e85-11eb-818b-21e7e8811ba4.png">

## 3) (Optional) SonarQube on Openshift
Provision SonarQube for code scanning on Openshift using the attached template.
```
oc process -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/sonarqube-persistent-template.yaml | oc create -f -

Or 
oc create -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/sonarqube-persistent-template.yaml
Then provision the SonarQube from the catalog
```
Login using admin/admin then update the password. 

Open SonarQube and create new project, give it a name, generate a token and use them as parameters in our next CI/CD steps

<img width="808" alt="Screen Shot 2021-01-03 at 17 01 17" src="https://user-images.githubusercontent.com/18471537/103481690-55f68180-4de5-11eb-8205-76cf44801c2a.png">

Make sure to select DotNet here.

## 4) Build Jenkins CI/CD using Jenkins File

Now create new pipeline for the project, where we checkout the code, run unit testing, run sonar qube analysis, build the application, get manual approval for deployment and finally deploy it on Openshift.  

Add this as pipeline script from SCM and populate it with our main branch in the git repository and cicd/jenkinsfile configurations.  

<img width="961" alt="Screen Shot 2021-02-09 at 17 02 22" src="https://user-images.githubusercontent.com/18471537/107382573-b1104800-6af8-11eb-9cdc-492b85e41104.png">

Here is the content of the file (as in cicd/jenkinsfile)

```
// Maintaned by Osama Oransa
// First execution will fail as parameters won't populated
// Subsequent runs will succeed if you provide correct parameters
def firstDeployment = "No";
pipeline {
	options {
		// set a timeout of 20 minutes for this pipeline
		timeout(time: 20, unit: 'MINUTES')
	}
    agent {
    // Using the dotnet builder agent
       label "dotnet-jenkins-slave"
    }
  stages {
    stage('Setup Parameters') {
            steps {
                script { 
                    properties([
                        parameters([
                        choice(
                                choices: ['Yes', 'No'], 
                                name: 'runSonarQube',
                                description: 'Run Sonar Qube Analysis?'
                            ),
                        string(
                                defaultValue: 'dev', 
                                name: 'proj_name', 
                                trim: true,
                                description: 'Openshift Project Name'
                            ),
                        string(
                                defaultValue: 'dotnet-app', 
                                name: 'app_name', 
                                trim: true,
                                description: 'Dotnet Application Name'
                            ),
                        string(
                                defaultValue: 'https://github.com/osa-ora/simple_dotnet', 
                                name: 'git_url', 
                                trim: true,
                                description: 'Git Repository Location'
                            ),
                        string(
                                defaultValue: 'sample_tests', 
                                name: 'test_folder', 
                                trim: true,
                                description: 'Unit Test Folder'
                            ),
                        string(
                                defaultValue: 'sample_app', 
                                name: 'app_folder', 
                                trim: true,
                                description: 'Application Folder'
                            ),
                        string(
                                defaultValue: 'http://sonarqube-cicd.apps.cluster-894c.894c.sandbox1092.opentlc.com', 
                                name: 'sonarqube_url', 
                                trim: true,
                                description: 'Sonar Qube URL'
                            ),
                        string(
                                defaultValue: 'dotnet', 
                                name: 'sonarqube_proj', 
                                trim: true,
                                description: 'Sonar Qube Project Name'
                            ),
                        password(
                                defaultValue: '25eece0a65f49b639dd7051480f84fd7445f5f5b', 
                                name: 'sonarqube_token', 
                                description: 'Sonar Qube Token'
                            )
                        ])
                    ])
                }
            }
    }
    stage('Code Checkout') {
      steps {
        git branch: 'main', url: '${git_url}'
        sh "ls -l"
      }
    }
    stage('Unit Testing & Code Coverage') {
      steps {
        sh "dotnet restore"
        sh "dotnet test --no-restore --collect:\"XPlat Code Coverage\" --logger trx"
        mstest testResultsFile:"**/*.trx", keepLongStdio: true
        cobertura coberturaReportFile: '**/coverage.cobertura.xml', enableNewApi: true, lineCoverageTargets: '0, 0, 0'
      }
    }
    stage('Code Scanning by Sonar Qube') {
        when {
            expression { runSonarQube == "Yes" }
        }
        steps {
            sh "dotnet sonarscanner begin /k:\"${sonarqube_proj}\" /d:sonar.host.url=\"${sonarqube_url}\" /d:sonar.login=\"${sonarqube_token}\""
            sh "dotnet build --no-restore"
            sh "dotnet sonarscanner end /d:sonar.login=\"${sonarqube_token}\""        
        }
    }
    stage('Build Deployment Package'){
        steps{
            sh "dotnet build --no-restore"
            archiveArtifacts '${app_folder}/bin/**/*.*'
        }
    }
    stage('Deployment Approval') {
        steps {
            timeout(time: 5, unit: 'MINUTES') {
                input message: 'Proceed with Application Deployment?', ok: 'Approve Deployment'
            }
        }
    }
    stage("Check Deployment Status"){
        steps {
            script {
              try {
                    sh "oc get svc/${app_name} -n=${proj_name}"
                    sh "oc get bc/${app_name} -n=${proj_name}"
                    echo 'Already deployed, incremental deployment will be initiated!'
                    firstDeployment = "No";
              } catch (Exception ex) {
                    echo 'Not deployed, initial deployment will be initiated!'
                    firstDeployment = "Yes";
              }
            }
        }
    }
    stage('Initial Deploy To Openshift') {
        when {
            expression { firstDeployment == "Yes" }
        }
        steps {
            sh "oc new-build --image-stream=dotnet:latest --binary=true --name=${app_name} -n=${proj_name}"
            sh "oc start-build ${app_name} --from-dir=${app_folder}/bin/Debug/netcoreapp3.1/. -n=${proj_name}"
            sh "oc logs -f bc/${app_name} -n=${proj_name}"
            sh "oc new-app ${app_name} --as-deployment-config -n=${proj_name}"
            sh "oc expose svc ${app_name} --port=8080 --name=${app_name} -n=${proj_name}"
        }
    }
    stage('Incremental Deploy To Openshift') {
        when {
            expression { firstDeployment == "No" }
        }
        steps {
            sh "oc start-build ${app_name} --from-dir=${app_folder}/bin/Debug/netcoreapp3.1/. -n=${proj_name}"
            sh "oc logs -f bc/${app_name} -n=${proj_name}"
        }
    }
    stage('Smoke Test') {
        steps {
            sleep(time:10,unit:"SECONDS")
            sh "curl \$(oc get route ${app_name} -n=${proj_name} -o jsonpath='{.spec.host}') | grep 'Web apps'"
        }
    }
  }
} // pipeline
```
As you can see this pipeline pick the dotnet slave image that we built, note the label must match what we configurd before:
```
agent {
    // Using the dotnet builder agent
       label "dotnet-jenkins-slave"
    }
```
Note that we provided the built binaries to the deployment, as both build and deploy machine has the same OS (both have linux-x64 as Runtime Identifier or RID), otherwise we need to use the target flag to specify the deployment machine OS or we can give Openshift the application folder and it will rebuild the application again before creating the container image.  
The pipeline uses many parameters in 1st execution, it will fail then in subsequent executions it will prepare the parameters:

<img width="1434" alt="Screen Shot 2021-02-02 at 14 29 16" src="https://user-images.githubusercontent.com/18471537/106600410-0f6e8100-6563-11eb-9799-7031bca61708.png">

Also note that you need to install MSTest Jenkins plugin in order to be able to publish the test results to Jenkins: From Manage Jenkins ==> Plugin Manager 

<img width="1004" alt="Screen Shot 2021-01-31 at 10 45 07" src="https://user-images.githubusercontent.com/18471537/106379107-5cf7bc00-63b2-11eb-93b4-ab910254fee5.png">

To be able to execute the code coverage report publishing and enforcement you need to install also Cobertura plugin

<img width="812" alt="Screen Shot 2021-02-02 at 14 09 41" src="https://user-images.githubusercontent.com/18471537/106600248-cfa79980-6562-11eb-9ef4-14e225027bc8.png">

Currently we set the coverage target to be 0 otherwise it will fail without enough line test coverage: lineCoverageTargets: '80, 60, 70'

```
[Cobertura] Code coverage enforcement failed for the following metrics:

[Cobertura]     Lines's stability is 0.0 and set mininum stability is 70.0.
```

## 5) Deployment Across Environments

Environments can be another Openshift project in the same Openshift cluster or in anither cluster.

In order to do this for the same cluster, you can enrich the pipeline and add approvals to deploy to a new project, all you need is to have the required privilages using "oc policy" as we did before and add deploy stage in the pipeline script to deploy into this project.

```
oc project {project_name} //this is new project to use
oc policy add-role-to-user edit system:serviceaccount:cicd:default -n {project_name}
oc policy add-role-to-user edit system:serviceaccount:cicd:jenkins -n {project_name}
```
Add more stages to the pipleine scripts like:
```
    stage('Deployment to Staging Approval') {
        steps {
            timeout(time: 5, unit: 'MINUTES') {
                input message: 'Proceed with Application Deployment in Staging environment ?', ok: 'Approve Deployment'
            }
        }
    }
    stage('Deploy To Openshift Staging') {
      steps {
        sh "oc project ${staging_proj_name}"
        sh "oc start-build ${app_name} --from-dir=."
        sh "oc logs -f bc/${app_name}"
      }
    }
```
You can use oc login command with different cluster to deploy the application into different clusters.
Also you can use Openshift plugin and configure different Openshift cluster to automated the deployments across many environments:

```
stage('preamble') {
	steps {
		script {
			openshift.withCluster() {
			//could be openshift.withCluster( 'another-cluster' ) {
				//name references a Jenkins cluster configuration
				openshift.withProject() { 
				//coulld be openshift.withProject( 'another-project' ) {
					//name references a project inside the cluster
					echo "Using project: ${openshift.project()} in cluster:  ${openshift.cluster()}"
				}
			}
		}
	}
}
```
And then configure any additonal cluster (other than the default one which running Jenkins) in Openshift Client plugin configuration section:

<img width="1400" alt="Screen Shot 2021-01-05 at 10 24 45" src="https://user-images.githubusercontent.com/18471537/103623100-4b043400-4f40-11eb-90cf-2209e9c4bde2.png">

## 6) Copy Container Images
In case you need to copy container images between different Openshift clusters, you can use Skopeo command to do this.
The easiest way is to copy the container to Quay.io repository and then import it.

In the docker folder you can see a Skopeo Jenkins slave image where you can use it to execute the copy command. Here is the steps that you need to do this:

From Quay Side:
1. Create Quay.io account and repository for example test repository
2. Create a Robot account in the respository with efficient permission e.g. read/write.   
From Openshift Side:  
3. Create Skopeo Jenkins slave image:
```
oc process -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/skopeo/bc_jenkins_slave_skopeo.yaml | oc create -f -
oc start-build bc/skopeo-jenkins-slave
oc logs -f bc/skopeo-jenkins-slave
```
Make sure this new image exist in Jenkins Pod Templates as we did before.  
4. Create User with enough privilages to pull the image for example skopeo user and get the token of this user
You can use either image-puller or image-builder based on the required use case
```
oc create serviceaccount skopeo
oc adm policy add-role-to-user system:image-puller -n cicd system:serviceaccount:cicd:skopeo
oc adm policy add-role-to-user system:image-builder -n cicd system:serviceaccount:cicd:skopeo
oc describe secret skopeo-token -n cicd
```
You can also use any user with privilage to do this.  
5. Create & Run Jenkins pipleline in that Skopeo slave to execute the copy command: (as in skopeo/jenkinsfile_skopeo_copy)

<img width="968" alt="Screen Shot 2021-02-10 at 10 24 04" src="https://user-images.githubusercontent.com/18471537/107486929-46115080-6b8e-11eb-8062-5023f9538990.png">

```
// Maintaned by Osama Oransa
// First execution will fail as parameters won't populated
// Subsequent runs will succeed if you provide correct parameters
pipeline {
    agent {
       // Using the skopeo agent
       label "jenkins-slave-skopeo"
    }
    stages {
      stage('Setup Parameters') {
            steps {
                script { 
                    properties([
                        parameters([
                        choice(
                                choices: ['To Quay', 'To Openshift'], 
                                name: 'copyDirection',
                                description: 'Copy Container to'
                            ),
                        string(
                                defaultValue: 'ooransa/tfs-agent-java8:latest', 
                                name: 'quay_repo', 
                                trim: true,
                                description: 'Quay Repository'
                            ),
                        string(
                                defaultValue: 'ooransa+test:token_here', 
                                name: 'quay_id', 
                                trim: true,
                                description: 'Quay Id (user/token)'
                            ),
                        string(
                                defaultValue: 'agent/newimage:latest', 
                                name: 'ocp_img_name', 
                                trim: true,
                                description: 'Openshift Image Name (project/image-steam:tag'
                            ),
                        string(
                                defaultValue: 'skopeo:token_here', 
                                name: 'ocp_id', 
                                trim: true,
                                description: 'Openshift Access Token (user:token)'
                            )
                        ])
                    ])
                }
            }
    }
      stage('Copy Image From Openshift To Quay') {
        when {
            expression { copyDirection == "To Quay" }
        }
        steps {
          sh "skopeo copy docker://image-registry.openshift-image-registry.svc:5000/${ocp_img_name} docker://quay.io/${quay_repo} --src-tls-verify=false --src-creds='${ocp_id}' --dest-creds ${quay_id}"
        }
      }
      stage('Copy Image From Quay To Openshift') {
        when {
            expression { copyDirection == "To Openshift" }
        }
        steps {
          sh "skopeo copy docker://quay.io/${quay_repo} docker://image-registry.openshift-image-registry.svc:5000/${ocp_img_name} --dest-tls-verify=false --format=v2s2 --src-creds='${quay_id}' --dest-creds ${ocp_id}"
        }
      }
    }
}
```
Where the parameters need to be supplied as per the Openshift and Quay configurations

<img width="523" alt="Screen Shot 2021-01-21 at 12 59 57" src="https://user-images.githubusercontent.com/18471537/105342131-a55fee80-5be8-11eb-8ae2-e4da79d18186.png">

Note that I used the flag srv-tls-verify=false and dest-tls-verity=false with OCP as in my environment it uses self signed certificate otherwise it will fail.  
Note also in case you encounter any issues in format versions you can use the flag "--format=v2s2"  
More details here: https://github.com/nmasse-itix/OpenShift-Examples/blob/master/Using-Skopeo/README.md. 
Also this useful one: https://github.com/RedHat-EMEA-SSA-Team/skopeo-ubi


## 7) Using Azure DevOps as CI/CD with Openshift Compute
In case you already have Azure DevOps platform and you need to use Openshift as compute power and deployment target for your application, you can configure this easily by doing the following steps:

1- Get Azure URL, and Personal Access Token.  
2- Create Agent Pool e.g. ocp_pool

<img width="382" alt="Screen Shot 2021-01-09 at 14 45 53" src="https://user-images.githubusercontent.com/18471537/104092058-25519480-528a-11eb-8f37-2d008daf4540.png">

3- Create the Openshift project and grant root execution for this project as the agent template run as a root and still some work required to make it secrure compliant with Openshift (run as non-root user)
```
oc new-project agent
oc adm policy add-scc-to-user anyuid -z default
```
4- Build the Agent Image on OCP using the template: bc_tfs_agent.yaml where you need to supply the following info:
```
oc create -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/agent/bc_tfs_agent.yaml

oc process -p GIT_URL=https://github.com/osa-ora/simple_dotnet -p GIT_BRANCH=main -p GIT_CONTEXT_DIR=agent -p DOCKERFILE_PATH=tfs_agent -p IMAGE_NAME=tfs-agent -p AGENT_NAME=myagent -p AZURE_URL=azure_url_here -p AZURE_TOKEN=token_here -p AZURE_POOL=ocp_pool  tfs-agent-template  | oc create -f -

```
Note: once the image is built, you can use the other template file: docker/bc_tfs_agent_local.yaml and populate the image stream configuration and other agent details.  
5- Once the Pod is up and running it will auto regster itself in Azure DevOps.

<img width="694" alt="Screen Shot 2021-01-09 at 14 45 35" src="https://user-images.githubusercontent.com/18471537/104092045-0a7f2000-528a-11eb-86a8-981ce5a971d6.png">

6- Create Service Account for Azure DevOps. 

```
oc project dev
oc create sa azure-devops
//dev is our deployment project target (you can change it if you are using another project name)
oc policy add-role-to-user edit system:serviceaccount:dev:azure-devops -n dev
//get the secret to use it in the login command
oc describe secret azure-devops-token
```
Now you have the token to use it in the pipeline or Openshift Azure DevOps plugin.  

7- Create a new pipeline in Azure DevOps.  
We can use DevOps Openshift plugin or write OC commands directly as in this pipeline:  
```
# Starter pipeline
# Start with a minimal pipeline that you can customize to build and deploy your code.
# Add steps that build, run tests, deploy, and more:
# https://aka.ms/yaml
parameters:
- name: firstRun
  default: false
  type: boolean
  displayName: 'First Run of this Pipeline'
- name: sonarQubeRun
  default: false
  type: boolean
  displayName: 'Run Sonar Qube Analysis'
- name: ocp_token
  default: 'token_here'
  type: string
  displayName: 'Openshift Auth Token'
- name: ocp_server
  default: 'https://api.cluster-66a1.66a1...opentlc.com:6443'
  type: string
  displayName: 'Openshift Server URL'
- name: proj_name
  default: 'dev'
  type: string
  displayName: 'Openshift Project Name'
- name: app_name
  default: 'dotnet-app'
  type: string
  displayName: 'Openshift Application Name'
- name: app_folder
  default: 'sample_app'
  type: string
  displayName: 'Application Folder'
- name: test_folder
  default: 'sample_tests'
  type: string
  displayName: 'Test Folder'
- name: sonar_proj
  default: 'dotnet'
  type: string
  displayName: 'SonarQube Project'
- name: sonar_token
  default: 'bf696b44d40d24b0f2396c8a3c231984e0207030'
  type: string
  displayName: 'SonarQube Token'
- name: sonar_url
  default: 'http://sonarqube-cicd.apps.cluster-894c.894c.sandbox1092.opentlc.com'
  type: string
  displayName: 'SonarQube Server URL'

trigger:
- main

pool:
  name: 'ocp_pool_java8'

steps:
- script: echo 'start pipeline'
  displayName: 'Run a Pipeline'

- script: |
    dotnet build
    dotnet test --no-restore --collect:"XPlat Code Coverage" --logger trx
  displayName: 'Build Application, Run Test Cases and Sonar Analysis'

- script: |
    dotnet sonarscanner begin /k:${{parameters.sonar_proj}} /d:sonar.host.url=${{parameters.sonar_url}}  /d:sonar.login=${{parameters.sonar_token}} 
    dotnet build
    dotnet sonarscanner end /d:sonar.login=${{parameters.sonar_token}}
  displayName: 'Run Sonar Qube Analysis'
  condition: eq('${{ parameters.sonarQubeRun }}', true)
- task: PublishTestResults@2
  condition: succeededOrFailed()
  inputs:
    testRunner: VSTest
    testResultsFiles: '${{parameters.test_folder}}/**/*.trx'
- task: PublishCodeCoverageResults@1
  inputs:
    codeCoverageTool: 'Cobertura'
    summaryFileLocation: '${{parameters.test_folder}}/**/coverage.cobertura.xml'
- task: PublishBuildArtifacts@1
  inputs:
    PathtoPublish: '$(System.DefaultWorkingDirectory)/${{parameters.app_folder}}/bin'
    ArtifactName: 'drop'
    publishLocation: 'Container'
- script: |    
    oc login --token=${{parameters.ocp_token}} --server=${{parameters.ocp_server}} --insecure-skip-tls-verify=true
    oc project ${{parameters.proj_name}}
    oc new-build --image-stream=dotnet:latest --binary=true --name=${{parameters.app_name}}
    oc start-build ${{parameters.app_name}} --from-dir=${{parameters.app_folder}}/bin/Debug/netcoreapp3.1/.
    oc logs -f bc/${{parameters.app_name}}
    oc new-app ${{parameters.app_name}} --as-deployment-config
    oc expose svc ${{parameters.app_name}} --port=8080 --name=${{parameters.app_name}}
  displayName: 'Deploy the application on first runs..'
  condition: eq('${{ parameters.firstRun }}', true)
- script: |   
    oc login --token=${{parameters.ocp_token}} --server=${{parameters.ocp_server}} --insecure-skip-tls-verify=true
    oc project ${{parameters.proj_name}}
    oc start-build ${{parameters.app_name}} --from-dir=${{parameters.app_folder}}/bin/Debug/netcoreapp3.1/.
    oc logs -f bc/${{parameters.app_name}}
  displayName: 'Deploy the application on subsequent runs..'
  condition: eq('${{ parameters.firstRun }}', false)
- script: |
    sleep 15
    curl $(oc get route ${{parameters.app_name}} -o jsonpath='{.spec.host}') | grep 'Web apps'
  displayName: 'Smoke Test'
```
Note that we provided the built binaries to the deployment, as both build and deploy machine has the same OS (both have linux-x64 as Runtime Identifier or RID), otherwise we need to use the target flag to specify the deployment machine OS or we can give Openshift the application folder and it will rebuild the application again before creating the container image.  

8- Run Azure DevOps Pipeline and Check the results
You'll see in the agent logs that it pick the job and execute it, and you will see in Azure DevOpe the pipleine exeuction:

<img width="704" alt="Screen Shot 2021-02-02 at 14 59 03" src="https://user-images.githubusercontent.com/18471537/106603745-61b1a100-6567-11eb-9101-76315a11125c.png">

You can also see the published test results:

<img width="1497" alt="Screen Shot 2021-02-02 at 14 59 21" src="https://user-images.githubusercontent.com/18471537/106603718-578fa280-6567-11eb-9af1-0156f7c3fa7d.png">

<img width="1483" alt="Screen Shot 2021-02-02 at 14 59 41" src="https://user-images.githubusercontent.com/18471537/106603692-4e9ed100-6567-11eb-94c4-86b6dd0a484a.png">


## 8) Using Webhooks & Openshift BuildConfig for CI/CD
You can also use webhooks as a way to build your application inside Openshift, and place this Webhook in whatever tool that can fire webhooks to make the CI/CD work smoothly.

For example: 
You can enable GitHub Webhook with any push of the code to fire Openshift BuildConfig to start a new build.
This is alternative to the command line: oc start-build command  

1) Pick the Webhook URL from your Openshift BuildConfig 

<img width="976" alt="Screen Shot 2021-02-02 at 15 11 50" src="https://user-images.githubusercontent.com/18471537/106605751-f0272200-6569-11eb-87e7-ab6e2dd2b3f9.png">

2) Configure GitHub webhook

<img width="1245" alt="Screen Shot 2021-02-02 at 15 05 06" src="https://user-images.githubusercontent.com/18471537/106605767-f3baa900-6569-11eb-893c-493b0c7f10d0.png">


3) Push any new code and your CI/CD will be working. 


As another alternative, you can also make use of GitHub Actions to build a workflow that execute build, test and then deploy to Openshift using webhook. 

<img width="565" alt="Screen Shot 2021-02-02 at 15 05 41" src="https://user-images.githubusercontent.com/18471537/106605191-49428600-6569-11eb-8f16-a6fcd9571408.png">

A simple workflow file looks like:  
```
name: .NET

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build:

    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v2
    - name: Setup .NET
      uses: actions/setup-dotnet@v1
      with:
        dotnet-version: 3.1.x
    - name: Restore dependencies
      run: dotnet restore
    - name: Build
      run: dotnet build --no-restore
    - name: Test
      run: dotnet test --no-build --logger trx --verbosity normal
    - name: CURL-ACTION
      # You may pin to the exact commit or the version.
      # uses: enflo/curl-action@fabe347922c7a9e88bafa15c4b7d6326ea802695
      uses: enflo/curl-action@v1.2
      with:
      # curl arguments
        curl: -k -X POST https://api.cluster-66a1......opentlc.com:6443/apis/build.openshift.io/v1/namespaces/dev/buildconfigs/simple-dotnet-git/webhooks/....../generic
          
```
You can also finally use Openshift GitHub plugin or any platform plugin as we saw in Jenkins Openshift plugin or Azure DevOpe Openshift Plugin.  

## 9) Using Tekton Pipeline

Similar to what we did in Jenkins or Azure DevOps, we can build the pipeline using TekTon. 
To do this we need to start by installing the SonarQube Tekton task for dotnet, DotNet Test Tekton task and Slack notification task using the following commands:

```
oc project cicd
oc apply -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/dotnet-sonarqube-scanner-with-login-param.yaml -n cicd
oc apply -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/dotnet-test.yaml -n cicd
oc apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/send-to-webhook-slack/0.1/send-to-webhook-slack.yaml
```
Note: In both dotnet test and sonarqube tasks, I used a ready made container image that has all the required tools already installed from the following source: https://hub.docker.com/r/nosinovacao/dotnet-sonar , you can use your own image or build it on Openshift, also I picked the 3.1 tag image, in case you need to do this for dotnet core 5.1, you can pick another image tag.

To configure Slcak notification, you need to have a slack channel and add app to it, then enable incoming-webhooks for this app.
Then you need to create a secret in Openshift with this incoming-wehbook url:
```
echo "kind: Secret
apiVersion: v1
metadata:
  name: webhook-secret
stringData:
  url: https://hooks.slack.com/services/........{the complete slack webhook url}" | oc create -f -
```
The slack channel will use this secret to post in the channel (note that this is an optional task).
Now, we can import the pipeline and grant the "pipeline" user edit rights on dev namespace to deploy the application there.
```
oc project cicd
oc apply -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/tekton.yaml -n cicd
oc policy add-role-to-user edit system:serviceaccount:cicd:pipeline -n dev
```
The following graph shows the pipeline steps and flow:

<img width="1499" alt="Screen Shot 2021-11-11 at 15 48 58" src="https://user-images.githubusercontent.com/18471537/141309151-c632805a-f119-4609-af07-402156dd6f07.png">

You can now, start the pipeline and select the proper parameters and fill in the dotnet-workspace where the pipeline shared input/outputs

<img width="864" alt="Screen Shot 2021-10-27 at 17 12 31" src="https://user-images.githubusercontent.com/18471537/139095241-3f07c433-21fa-4d1b-abde-b0611f183891.png">

Once the execution is completed, you will see the pipeline run output and logs and you can then access the deployed application:

With successful execution:
<img width="1475" alt="Screen Shot 2021-11-11 at 15 50 10" src="https://user-images.githubusercontent.com/18471537/141309327-610550bc-ca25-40ae-b1c5-23b8366aab8b.png">

With failed execution:
<img width="1475" alt="Screen Shot 2021-11-11 at 15 50 58" src="https://user-images.githubusercontent.com/18471537/141309438-592785f6-30a7-4411-a692-16ab34b6bad9.png">

You will get slack notifications accordingly when the pipeline start the execution and at the end with the pipeline execution results, if you don't want to use it, you can just set the slack notification parameter in the pipeline as false. 

<img width="665" alt="Screen Shot 2021-11-11 at 15 51 29" src="https://user-images.githubusercontent.com/18471537/141309521-d85d47ec-f2c4-4d2a-b88c-822355e1eec1.png">

Note: We have used source2image task to deploy the application, but we could just use Openshift binary build (oc) for the generated .dll files similar to what we did in Jenkins or Azure DevOps pipeline, but we used s2i task here for more demonstration of the available options.

** Automate the pipeline using Tekton Triggers:

Now to automate the pipeline we can add trigger to our pipeline to fire it once a new push is created, go to pipeline and click on Add trigger. 

<img width="135" alt="Screen Shot 2021-10-28 at 08 33 34" src="https://user-images.githubusercontent.com/18471537/139200543-9ee9bf9d-7486-491e-b50a-3c3282305147.png">

Then select GitHub Push to fire the pipeline on push event, as you can see many triggers are available for GitHub, GitLab and BitBucket at the moment. 

<img width="874" alt="Screen Shot 2021-10-28 at 08 37 26" src="https://user-images.githubusercontent.com/18471537/139200638-c404efaf-9218-487e-8a25-3030e74d00b8.png">

Now let's take the generated webhook url from our pipeline. 

<img width="687" alt="Screen Shot 2021-10-28 at 08 33 59" src="https://user-images.githubusercontent.com/18471537/139200738-8576af9d-a695-4886-b9bb-2298edea1aac.png">

Now go to GitHub settings and add Webhook. 

<img width="520" alt="Screen Shot 2021-10-28 at 08 34 44" src="https://user-images.githubusercontent.com/18471537/139201058-e4c2d89c-1de4-45bd-b38e-9dcc2096382f.png">

Finally push any code to your repository and it will trigger the pipeline execution. 

<img width="1466" alt="Screen Shot 2021-10-28 at 08 35 07" src="https://user-images.githubusercontent.com/18471537/139201232-ab44a2be-e503-441e-992b-94ed6db440af.png">





