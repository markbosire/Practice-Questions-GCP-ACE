#!/bin/bash

# Set project ID

# Create VPC
gcloud compute networks create mern-vpc --subnet-mode=custom

# Create subnet
gcloud compute networks subnets create mern-subnet \
    --network=mern-vpc \
    --region=us-central1 \
    --range=10.0.0.0/24

# Create firewall rules
gcloud compute firewall-rules create allow-internal \
    --network mern-vpc \
    --allow tcp,udp,icmp \
    --source-ranges 10.0.0.0/24

gcloud compute firewall-rules create allow-external \
    --network mern-vpc \
    --allow tcp:22,tcp:80,tcp:443 \
    --source-ranges 0.0.0.0/0

# Create MongoDB startup script
cat << EOF > mongodb_startup.sh
 Update and upgrade the system
    sudo apt-get update
    sudo apt-get upgrade -y
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m System updated and upgraded successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to update and upgrade the system."
      exit 1
    fi

    # Install MongoDB
    sudo apt-get install -y gnupg curl
    curl -fsSL https://www.mongodb.org/static/pgp/server-4.4.asc | sudo apt-key add -
    echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu bionic/mongodb-org/4.4 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.4.list
    sudo apt-get update
    sudo apt-get install -y mongodb-org
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m MongoDB installed successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to install MongoDB."
      exit 1
    fi

    # Configure MongoDB for remote access before starting the service
    LOCAL_IP=$(hostname -I | awk '{print $21}')
    sudo sed -i "s/bindIp: 127.0.0.1/bindIp: 0.0.0.0/" /etc/mongod.conf
    echo -e "\e[32m[SUCCESS]\e[0m MongoDB configured to listen on all interfaces."

    # Start MongoDB service
    sudo systemctl start mongod
    sudo systemctl enable mongod
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m MongoDB service started and enabled."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to start MongoDB service."
      exit 1
    fi

    # Wait for MongoDB to be ready
    echo "Waiting for MongoDB to be ready..."
    sleep 10

    # Create admin user
    mongo admin --eval '
      db.createUser({
        user: "admin",
        pwd: "password",
        roles: [ { role: "userAdminAnyDatabase", db: "admin" } ]
      })
    '
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m Admin user created in MongoDB."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to create admin user. Check MongoDB logs for details."
      exit 1
    fi

    # Enable authentication
    sudo sed -i 's/#security:/security:\n  authorization: enabled/' /etc/mongod.conf

    # Restart MongoDB to apply changes
    sudo systemctl restart mongod
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m MongoDB restarted with new configuration."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to restart MongoDB."
      exit 1
    fi

    echo -e "\e[1;32m[SETUP COMPLETE]\e[0m MongoDB is installed, configured, and ready to use."
    echo -e "You can connect to MongoDB using: mongo -u admin -p password --authenticationDatabase admin"
EOF

# Create MongoDB instance
gcloud compute instances create mongodb-instance \
    --zone=us-central1-a \
    --machine-type=e2-medium \
    --subnet=mern-subnet \
    --image-family=ubuntu-pro-1804-bionic-v20240924  \
    --image-project=ubuntu-os-pro-cloud \
    --tags=mongodb \
    --metadata-from-file startup-script=mongodb_startup.sh

# Get MongoDB instance internal IP
MONGO_IP=$(gcloud compute instances describe mongodb-instance --zone=us-central1-a --format='get(networkInterfaces[0].networkIP)')

# Create MERN startup script
cat << EOF > mern_startup.sh
 Update the system
    sudo apt-get update
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m System updated successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to update the system."
      exit 1
    fi

    # Install Node.js and npm
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m Node.js and npm installed successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to install Node.js and npm."
      exit 1
    fi

    # Install git
    sudo apt-get install -y git
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m Git installed successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to install Git."
      exit 1
    fi

    # Clone the repository
    git clone https://github.com/markbosire/simplemern.git
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m Repository cloned successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to clone the repository."
      exit 1
    fi

    # Navigate to the project directory
    cd simplemern
    PROJECT_DIR=$(pwd)
    echo "Project directory: $PROJECT_DIR"

    # Install backend dependencies
    npm install
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m Backend dependencies installed successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to install backend dependencies."
      exit 1
    fi

    # Install frontend dependencies
    cd client
    npm install
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m Frontend dependencies installed successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to install frontend dependencies."
      exit 1
    fi

    # Create backend .env file
    echo "MONGO_URI=mongodb://admin:password@192.168.56.10:27017" > ../.env
    echo "IP=$(hostname -I | awk '{print $1}')" >> ../.env
    echo -e "\e[33m[WARNING]\e[0m Don't forget to replace the MongoDB URI in the backend .env file with your actual MongoDB URI."

    # Create frontend .env file
    echo "VITE_API_IP=$(hostname -I | awk '{print $1}')" > .env
    echo -e "\e[32m[SUCCESS]\e[0m Frontend .env file created with dynamic VM host IP."

    # Build the frontend
    npm run build
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m Frontend built successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to build the frontend."
      exit 1
    fi

    # Install Nginx
    sudo apt-get install -y nginx
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m Nginx installed successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to install Nginx."
      exit 1
    fi

    # Configure Nginx
    sudo wget -O /etc/nginx/sites-available/mern-app https://raw.githubusercontent.com/markbosire/nba-web-scrapping/refs/heads/main/mern-app

    # Enable the Nginx site
    sudo ln -s /etc/nginx/sites-available/mern-app /etc/nginx/sites-enabled/
    sudo rm /etc/nginx/sites-enabled/default
    sudo nginx -t
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m Nginx configuration test passed."
    else
      echo -e "\e[31m[ERROR]\e[0m Nginx configuration test failed."
      exit 1
    fi

    sudo systemctl restart nginx
    echo -e "\e[32m[SUCCESS]\e[0m Nginx restarted."

    # Add www-data user to the first user's group
    first_user=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }' /etc/passwd)
    if sudo usermod -a -G $first_user www-data; then
      echo -e "\e[32m[SUCCESS]\e[0m www-data added to $first_user's group."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to add www-data to $first_user's group."
    fi

    # Change ownership of directories to the first user (vagrant in this case)
    if sudo chown -R $first_user:$first_user /home/$first_user/simplemern; then
      echo -e "\e[32m[SUCCESS]\e[0m Ownership of /home/$first_user/simplemern changed to $first_user."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to change ownership of /home/$first_user/simplemern."
    fi

    # Set permissions for the first user's home directory
    if sudo chmod 750 /home/$first_user/; then
      echo -e "\e[32m[SUCCESS]\e[0m Permissions set to 750 for /home/$first_user."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to set permissions for /home/$first_user."
    fi

    # Set permissions for the project directory and its subdirectories
    if sudo chmod 750 /home/$first_user/simplemern; then
      echo -e "\e[32m[SUCCESS]\e[0m Permissions set to 750 for /home/$first_user/simplemern."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to set permissions for /home/$first_user/simplemern."
    fi

    if sudo chmod 750 /home/$first_user/simplemern/client; then
      echo -e "\e[32m[SUCCESS]\e[0m Permissions set to 750 for /home/$first_user/simplemern/client."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to set permissions for /home/$first_user/simplemern/client."
    fi

    if sudo chmod 750 /home/$first_user/simplemern/client/dist; then
      echo -e "\e[32m[SUCCESS]\e[0m Permissions set to 750 for /home/$first_user/simplemern/client/dist."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to set permissions for /home/$first_user/simplemern/client/dist."
    fi
    sudo systemctl restart nginx
    echo -e "\e[32m[SUCCESS]\e[0m Nginx restarted."

    # Install PM2 globally
    sudo npm install -g pm2
    if [ $? -eq 0 ]; then
      echo -e "\e[32m[SUCCESS]\e[0m PM2 installed successfully."
    else
      echo -e "\e[31m[ERROR]\e[0m Failed to install PM2."
      exit 1
    fi

    # Start the backend server
    cd $PROJECT_DIR
    pm2 start app.js
    echo -e "\e[32m[SUCCESS]\e[0m Backend server started with PM2."

    echo -e "\e[1;32m[SETUP COMPLETE]\e[0m MERN Stack application is set up and running in production mode."
    echo -e "You can access the application at http://$(hostname -I | awk '{print $1}')"
    echo -e "Don't forget to replace the MongoDB URI in the backend .env file with your actual MongoDB URI."
EOF

# Create MERN instance
gcloud compute instances create mern-instance \
    --zone=us-central1-a \
    --machine-type=e2-medium \
    --subnet=mern-subnet \
    --image-family=ubuntu-2204-jammy-v20240927  \
    --image-project=ubuntu-os-cloud \
    --tags=http-server,https-server \
    --metadata-from-file startup-script=mern_startup.sh

# Create health check
gcloud compute health-checks create http mern-health-check \
    --port=80

# Create backend service
gcloud compute backend-services create mern-backend \
    --protocol=HTTP \
    --port-name=http \
    --health-checks=mern-health-check \
    --global

# Add instance to backend service
gcloud compute backend-services add-backend mern-backend \
    --instance-name=mern-instance \
    --instance-zone=us-central1-a \
    --global

# Create URL map
gcloud compute url-maps create mern-url-map \
    --default-service mern-backend

# Create HTTP proxy
gcloud compute target-http-proxies create mern-http-proxy \
    --url-map mern-url-map

# Create global forwarding rule
gcloud compute forwarding-rules create mern-http-rule \
    --global \
    --target-http-proxy=mern-http-proxy \
    --ports=80

# Output load balancer IP
echo "Load Balancer IP:"
gcloud compute forwarding-rules describe mern-http-rule \
    --global \
    --format="value(IPAddress)"

echo "Access your application at: http://$(gcloud compute forwarding-rules describe mern-http-rule --global --format='value(IPAddress)')"

# Cleanup startup script files
rm mongodb_startup.sh mern_startup.sh
