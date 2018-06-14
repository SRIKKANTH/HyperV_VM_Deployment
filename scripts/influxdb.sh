setup_type=$1
if [ ! -f azuremodules.sh ]; then
    wget https://raw.githubusercontent.com/SRIKKANTH/HelperScripts/master/bash/azuremodules.sh
fi
. azuremodules.sh

LogFile="LogFile.log"
pkill tail > /dev/null
touch $LogFile 
tail -f $LogFile &
 
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
	echo y | sudo ufw allow 8086/tcp | LogMsg
	echo y | sudo ufw allow 8083/tcp | LogMsg
	echo y | sudo ufw allow 8888/tcp | LogMsg

	echo y | sudo ufw enable | LogMsg
	ufwstatus=`sudo ufw status`
	echo "ufw status ${ufwstatus}" | LogMsg
}

function InstallDocker()
{
    if [[ `which docker` != "" ]]
    then
        echo "Info: 'docker' is already installed skipping ..."
    else
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
	fi

	OpenPorts
}

function SetupInfluxdbContainer()
{
	echo "Info: Influxdb initialization started" | LogMsg
	InstallDocker

	INFLUX_DB_PATH=/datadrive
	mkdir $INFLUX_DB_PATH
	docker network create influxdb

	docker run -d -p 8086:8086 \
		-v $INFLUX_DB_PATH:/var/lib/influxdb \
		--net=influxdb \
		--name influxdb influxdb 2>&1 | LogMsg	
	
	docker run -d -p 8888:8888 \
		--net=influxdb\
		chronograf --influxdb-url=http://`get_one_ip`:8086

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
		echo "influxdb-url=http://`get_one_ip`:8086" | LogMsg
		echo "chronograf-url=http://`get_one_ip`:8888" | LogMsg
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

SetupInfluxdbContainer

