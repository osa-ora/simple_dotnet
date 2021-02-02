# Openshift CI/CD for simple DotNet Application

This Project Handle the basic CI/CD of DotNet application 

To run locally with DotNet installed:   

```
dotnet test Tests --logger trx 
dotnet build
dotnet run
```

To use Jenkins on Openshift for CI/CD, first we need to build DotNet Jenkins Slave template to use in our CI/CD 

## 1) Build The Environment

Run the following commands to build the environment and provision Jenkins and its slaves templates:  

```
oc project cicd //this is the project for cicd

oc create -f bc_jenkins_slave_template.yaml -n cicd //this will add the template to use 
or you can use it directly from the GitHub: oc process -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/bc_jenkins_slave_template.yaml -n cicd | oc create -f -

Now use the template to create the Jenkins slave template
oc describe template jenkins-slave-template //to see the template details
oc process -p GIT_URL=https://github.com/osa-ora/simple_dotnet -p GIT_BRANCH=main -p GIT_CONTEXT_DIR=cicd -p DOCKERFILE_PATH=dockerfile_dotnet_node -p IMAGE_NAME=jenkins-dotnet-slave jenkins-slave-template | oc create -f -

oc start-build jenkins-dotnet-slave 
oc logs bc/jenkins-dotnet-slave -f

oc new-app jenkins-persistent  -p MEMORY_LIMIT=2Gi  -p VOLUME_CAPACITY=4Gi -n cicd

oc project dev //this is project for application development
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
Now click on Pod Templates, add new one with name "jenkins-dotnet-slave", label "jenkins-dotnet-slave", container template name "jnlp", docker image "image-registry.openshift-image-registry.svc:5000/cicd/jenkins-dotnet-slave" 

See the picture:
<img width="1242" alt="Screen Shot 2021-01-04 at 12 09 05" src="https://user-images.githubusercontent.com/18471537/103524212-d2d93800-4e85-11eb-818b-21e7e8811ba4.png">

## 3) (Optional) SonarQube on Openshift
Provision SonarQube for code scanning on Openshift using the attached template.
oc process -f https://raw.githubusercontent.com/osa-ora/simple_dotnet/main/cicd/sonarqube-persistent-template.yaml | oc create -f -

Open SonarQube and create new project, give it a name, generate a token and use them as parameters in our next CI/CD steps

<img width="808" alt="Screen Shot 2021-01-03 at 17 01 17" src="https://user-images.githubusercontent.com/18471537/103481690-55f68180-4de5-11eb-8205-76cf44801c2a.png">

Make sure to select DotNet here.

## 4) Build Jenkins CI/CD using Jenkins File

Now create new pipeline for the project, where we checkout the code, run unit testing, run sonar qube analysis, build the application, get manual approval for deployment and finally deploy it on Openshift.
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
       label "jenkins-slave-dotnet"
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
       label "jenkins-dotnet-slave"
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
oc process -p GIT_URL=https://github.com/osa-ora/simple_dotnet -p GIT_BRANCH=main -p GIT_CONTEXT_DIR=skopeo -p DOCKERFILE_PATH=dockerfile_skopeo -p IMAGE_NAME=jenkins-slave-skopeo jenkins-slave-template | oc create -f -
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
5. Run Jenkins pipleline in that Skopeo slave to execute the copy command: (as in docker/jenkinsfile_skopeo_copy)
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
  default: 'https://api.cluster-66a1.66a1.sandbox1049.opentlc.com:6443'
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
    dotnet test ${{parameters.test_folder}} --logger trx --no-restore
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
    oc logout
  displayName: 'Deploy the application on first runs..'
  condition: eq('${{ parameters.firstRun }}', true)
- script: |   
    oc login --token=${{parameters.ocp_token}} --server=${{parameters.ocp_server}} --insecure-skip-tls-verify=true
    oc project ${{parameters.proj_name}}
    oc start-build ${{parameters.app_name}} --from-dir=${{parameters.app_folder}}/bin/Debug/netcoreapp3.1/.
    oc logs -f bc/${{parameters.app_name}}
    oc logout
  displayName: 'Deploy the application on subsequent runs..'
  condition: eq('${{ parameters.firstRun }}', false)
- script: |
    sleep 15
    oc login --token=${{parameters.ocp_token}} --server=${{parameters.ocp_server}} --insecure-skip-tls-verify=true
    curl $(oc get route ${{parameters.app_name}} -o jsonpath='{.spec.host}') | grep 'Web apps'
    oc logout
  displayName: 'Smoke Test'
```
Note that we provided the built binaries to the deployment, as both build and deploy machine has the same OS (both have linux-x64 as Runtime Identifier or RID), otherwise we need to use the target flag to specify the deployment machine OS or we can give Openshift the application folder and it will rebuild the application again before creating the container image.  

8- Run Azure DevOps Pipeline and Check the results
You'll see in the agent logs that it pick the job and execute it, and you will see in Azure DevOpe the pipleine exeuction:

<img width="704" alt="Screen Shot 2021-02-02 at 14 59 03" src="https://user-images.githubusercontent.com/18471537/106603745-61b1a100-6567-11eb-9101-76315a11125c.png">

You can also see the published test results:

<img width="1497" alt="Screen Shot 2021-02-02 at 14 59 21" src="https://user-images.githubusercontent.com/18471537/106603718-578fa280-6567-11eb-9af1-0156f7c3fa7d.png">

<img width="1483" alt="Screen Shot 2021-02-02 at 14 59 41" src="https://user-images.githubusercontent.com/18471537/106603692-4e9ed100-6567-11eb-94c4-86b6dd0a484a.png">
