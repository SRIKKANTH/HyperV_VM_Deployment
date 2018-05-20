setup_type=$1
if [ ! -f azuremodules.sh ]; then
    wget https://raw.githubusercontent.com/SRIKKANTH/HyperV_VM_Deployment/master/scripts/azuremodules.sh
fi
. azuremodules.sh

LogFile="LogFile.log"
pkill tail > /dev/null
if [ "x$setup_type" != "x" ]
then
	touch $LogFile 
	tail -f $LogFile &
fi
 
function InstallDockerFromGetDockerDotCom ()
{
    sudo docker --version | grep "Docker version" | LogMsg
    if [ $? -eq 0 ]
	then
		sudo systemctl start docker
		echo "Docker already installed" | LogMsg
    else
		echo "Installing Docker" | LogMsg
		#TODO Should we install docker via someother means ?for example apt-get install docker-ce
		wget -qO- https://get.docker.com/ | sh

		if [ $? -ne 0 ] 
		then
			echo "docker install failed" | LogMsg
			return 1
		fi
		
		echo "Installing Docker:Done" | LogMsg
		# Commenting below out as currently custom extension script is run as root. 
		# The virtualmachine admin user has sudo permission currently so below may not be required anyways.
		# if required put in a seperate function and get admin user from FSM as here the $USER will always be root
		#sudo usermod -aG docker $USER
    fi
    DockerStatus=`get_service_status docker`
	if [ "x$DockerStatus" == "running" ]
	then
		echo "Docker Installed Succesfully"  | LogMsg
		return 1
	elif [ "x$DockerStatus" == "dead" ]
	then
		echo "Docker Installed succesfully but service not started" | LogMsg
		return 1
	elif [ "x$DockerStatus" == "ServiceNotFound" ]
	then
		echo "Error: Docker Installation Failed" | LogMsg
		return 2
	fi
}

function InstallDockerFromRepo ()
{
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - | LogMsg  
	check_exit_status | LogMsg 
	sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | LogMsg
	check_exit_status | LogMsg
	sudo apt-get update | LogMsg
	check_exit_status  | LogMsg
	sudo apt-cache policy docker-ce | LogMsg
	check_exit_status  | LogMsg
	sudo apt-get install -y docker-ce | LogMsg
	check_exit_status  | LogMsg
	sudo systemctl status docker | LogMsg
	check_exit_status  | LogMsg
	DockerStatus=`get_service_status docker`
	if [ "x$DockerStatus" == "running" ]
	then
		echo "Docker Installed Succesfully"  | LogMsg
		return 1
	elif [ "x$DockerStatus" == "dead" ]
	then
		echo "Docker Installed succesfully but service not started" | LogMsg
		return 1
	elif [ "x$DockerStatus" == "ServiceNotFound" ]
	then
		echo "Error: Docker Installation Failed" | LogMsg
		return 2
	fi
}

function OpenPorts ()
{
	#SSH port
	echo y | sudo ufw allow 22/tcp | LogMsg

	if [ $setup_type == "DebugContainer" ] 
	then
		echo y | sudo ufw allow 222/tcp | LogMsg
		echo y | sudo ufw allow 5000/tcp | LogMsg
	elif [ $setup_type == "InfluxdbContainer" ] 
	then
		echo y | sudo ufw allow 8086/tcp | LogMsg
		echo y | sudo ufw allow 8083/tcp | LogMsg
	fi
	
	echo y | sudo ufw enable | LogMsg
	ufwstatus=`sudo ufw status`
	echo "ufw status ${ufwstatus}" | LogMsg
}

function RegistryLogin ()
{
	registryUserName=$1
	registrypassword=$2
	sudo docker login $REGISTRY_URL -u $registryUserName -p $registrypassword
	if [ $? -ne 0 ] 
	then
	  echo "registry account login failed!"
	  return 1
	fi
}


function InstallDocker()
{
    if [[ `which docker` != "" ]]
    then
        echo "Info: 'docker' is already installed skipping ..."
    fi

    echo "Info: Installing 'docker' ..."

	InstallDockerFromRepo
	Status=$?
	if [ $Status -eq 1 ]
	then
		set_service_status docker restart
	elif [ $Status -gt 1 ]
	then
		echo "Warning: InstallDockerFromRepo failed to install 'docker'" | LogMsg
		InstallDockerFromGetDockerDotCom
		Status=$?
		if [ $Status -eq 1 ]
		then
			set_service_status docker restart
		elif [ $Status -gt 1 ]
		then
			echo "Error: Failed to Install docker exitting now" | LogMsg
			echo "DOCKER_INSTALLATION_FAILED" | UpdateStatus
		fi
	fi
	
	echo "Info: Installation of docker succesfully finished" | LogMsg		
	echo "DOCKER_INSTALLATION_SUCCESS" | UpdateStatus

	if [ $? -ne 0 ] 
	then 
		exit 1 
	fi

	OpenPorts
}

function InstallFluentDContainer ()
{
	containername=$FLUENTD_CONTAINER_NAME
	imagename=$1
	fileDirectory="/etc/fluentd"
	
	if [ ! -d "$fileDirectory" ]
	then
		mkdir -p "$fileDirectory"
		echo "Created fluentd folder "
	fi
	
	curl https://manishdbenginetest.blob.core.windows.net/fluentdcontainerfiles/td-agent.conf > $fileDirectory/td-agent.conf

	if [ -e $fileDirectory/td-agent.conf ]
	then
		echo "Info: Downloaded required files for FluentD: td-agent.conf"
	else
		echo "Error: Failed to download required files for FluentD: td-agent.conf"
		return 1
	fi	
	
	docker images | grep $imagename > /dev/null 2>&1	
	if [ $? -ne 0 ] 
	then
		echo "Pulling FLUENTD Image from Registry"
		sudo docker pull $imagename
	fi
	
	echo "Creating FLUENTD container"
	sudo docker ps | grep $containername > /dev/null 2>&1
	if [ $? -eq 0 ] 
	then
		echo "fluentd already installed"
		return
	fi
	
	sudo docker run -d -p 24224:24224 -v $HOME/fluentd:/etc/fluentd -v $HOME/runmdsd:/var/run/mdsd -e FLUENTD_CONF=/etc/fluentd/td-agent.conf --name=$containername $imagename

	sudo docker ps | grep $containername > /dev/null 2>&1	
	if [ $? -ne 0 ] 
	then
		echo "fluentd install failed"
		return 1
	fi
	
	echo "InstallFluentDContainer:Done"
}

function SetupDebugContainer()
{
	echo "Info: SetupDebugContainer started" | LogMsg
	InstallDocker

cat >Dockerfile <<EOL
FROM ubuntu:16.04
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial main restricted"  > /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial-updates main restricted" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial universe" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial-updates universe" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial multiverse" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial-updates multiverse" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial-backports main restricted universe multiverse" >> /etc/apt/sources.list
RUN echo "deb http://security.ubuntu.com/ubuntu xenial-security main restricted" >> /etc/apt/sources.list
RUN echo "deb http://security.ubuntu.com/ubuntu xenial-security universe" >> /etc/apt/sources.list
RUN echo "deb http://security.ubuntu.com/ubuntu xenial-security multiverse" >> /etc/apt/sources.list

RUN apt-get update
RUN apt-get install openssh-server unzip curl apt-transport-https -y
RUN curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
RUN mv microsoft.gpg /etc/apt/trusted.gpg.d/microsoft.gpg
RUN sh -c 'echo "deb [arch=amd64] https://packages.microsoft.com/repos/microsoft-ubuntu-xenial-prod xenial main" > /etc/apt/sources.list.d/dotnetdev.list'
RUN apt-get update
RUN apt-get install -y dotnet-sdk-2.0.3 dotnet-hosting-2.0.6

RUN mkdir /var/run/sshd
RUN echo 'root:screencast' | chpasswd
RUN sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd
ENV NOTVISIBLE "in users profile"
RUN echo "export VISIBLE=now" >> /etc/profile
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]
EOL
	
	docker build -t ubuntu1604_dotnet_installed .  | LogMsg
	docker run -d -P  -p  222:22 -p 5000:5000 -v /root:/root -v /etc/shadow:/etc/shadow --name u1604_dotnet_debug ubuntu1604_dotnet_installed | LogMsg
	if [ $? -ne 0 ] 
	then 
		echo "Error: Failed to setup DebugContainer!" | LogMsg
		echo "DEBUG_CONTAINER_INITIALISATION_FAILED" | UpdateStatus
		exit 1 
	else
		echo "Info: DebugContainer initialised succesfully" | LogMsg
		echo "DEBUG_CONTAINER_INITIALISATION_SUCCESS" | UpdateStatus
	fi

	docker port u1604_dotnet_debug | LogMsg
}

function SetupInfluxdbContainer()
{
	echo "Info: Influxdb initialization started" | LogMsg
	InstallDocker

	INFLUX_DB_PATH=$PWD

	docker run -d -p 8086:8086 \
		  -v $INFLUX_DB_PATH:/var/lib/influxdb \
		   --name influxdb influxdb 2>&1 | LogMsg

	if [ $? -ne 0 ] 
	then 
		exit 1 
	fi
	sleep 4
	if [ `curl -sl -I http://localhost:8086/ping | grep X-Influxdb-Version| wc -l`  != 1 ] 
	then 
		echo "Error: Failed to initialise Influxdb!" | LogMsg
		echo "INFLUXDB_INITIALISATION_FAILED" | UpdateStatus
		exit 1 
	else
		echo "Info: Influxdb initialised succesfully" | LogMsg
		echo "INFLUXDB_INITIALISATION_SUCCESS" | UpdateStatus
	fi
	docker port influxdb | LogMsg
	return 0
}

########################################################################
#
#	Execution starts from here
#
########################################################################

case "$setup_type" in
	DebugContainer)
		SetupDebugContainer
		;;

	InfluxdbContainer)
		SetupInfluxdbContainer
		;;
	-h|--help|-help)
		echo "Usage: "
		echo "$0 <DebugContainer|InfluxdbContainer|>"
		echo "$0 DebugContainer	: Prepares an ubuntu1604 container with dotnet installed"
		echo "$0 InfluxdbContainer	: Prepares an Influxdb container"
		echo "$0	: Sources the contents and doesnt execute any functionality"
		;;
	*)
		echo "No functionality is called just sourcing contens of $0"
		bash ./$0 -h
esac


