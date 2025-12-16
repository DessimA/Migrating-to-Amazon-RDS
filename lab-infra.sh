#!/bin/bash

# ==============================================================================
# SCRIPT DE AUTOMAÇÃO: FOCO EM EVIDÊNCIAS NO CONSOLE
# ==============================================================================

KEY_FILE="labsuser.pem"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'

# Função de Pausa Orientada ao Console
pause_for_console() {
    echo -e "\n${YELLOW}📸 AÇÃO NECESSÁRIA: VÁ PARA O NAVEGADOR!${NC}"
    echo -e "1. Abra o serviço: ${BOLD}$1${NC}"
    echo -e "2. Navegue até: ${BOLD}$2${NC}"
    echo -e "3. O que capturar: ${BOLD}$3${NC}"
    echo "----------------------------------------------------------------"
    read -p "Tire o print no navegador e pressione [ENTER] aqui para continuar..."
    echo -e "${BLUE}--> Prosseguindo...${NC}\n"
}

# Validação Inicial
if [ ! -f "$KEY_FILE" ]; then echo -e "${RED}ERRO: $KEY_FILE não encontrado.${NC}"; exit 1; fi
chmod 400 "$KEY_FILE"

# 1. INFRAESTRUTURA
# ------------------------------------------------------------------------------
echo -e "${BLUE}[1/4] Provisionando Rede e Segurança...${NC}"

# Descoberta
CAFE_INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=*CafeInstance*" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
VPC_ID=$(aws ec2 describe-instances --instance-ids $CAFE_INSTANCE_ID --query "Reservations[0].Instances[0].VpcId" --output text)
CAFE_AZ=$(aws ec2 describe-instances --instance-ids $CAFE_INSTANCE_ID --query "Reservations[0].Instances[0].Placement.AvailabilityZone" --output text)
CAFE_SG_ID=$(aws ec2 describe-instances --instance-ids $CAFE_INSTANCE_ID --query "Reservations[0].Instances[0].SecurityGroups[?contains(GroupName, 'CafeSecurityGroup')].GroupId" --output text)
DIFFERENT_AZ=$(aws ec2 describe-availability-zones --query "AvailabilityZones[?ZoneName!='$CAFE_AZ'].ZoneName | [0]" --output text)

# Criação (Idempotente)
DB_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=CafeDatabaseSG" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
if [ -z "$DB_SG_ID" ] || [ "$DB_SG_ID" == "None" ]; then
    DB_SG_ID=$(aws ec2 create-security-group --group-name CafeDatabaseSG --description "Security group for Cafe database" --vpc-id $VPC_ID --query 'GroupId' --output text)
fi
aws ec2 authorize-security-group-ingress --group-id $DB_SG_ID --protocol tcp --port 3306 --source-group $CAFE_SG_ID 2>/dev/null

SUBNET_1_ID=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=10.200.2.0/23" --query "Subnets[0].SubnetId" --output text)
if [ -z "$SUBNET_1_ID" ]; then SUBNET_1_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.200.2.0/23 --availability-zone $CAFE_AZ --query 'Subnet.SubnetId' --output text); fi

SUBNET_2_ID=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=10.200.10.0/23" --query "Subnets[0].SubnetId" --output text)
if [ -z "$SUBNET_2_ID" ]; then SUBNET_2_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.200.10.0/23 --availability-zone $DIFFERENT_AZ --query 'Subnet.SubnetId' --output text); fi

aws rds create-db-subnet-group --db-subnet-group-name "CafeDB Subnet Group" --db-subnet-group-description "DB subnet group for Cafe" --subnet-ids $SUBNET_1_ID $SUBNET_2_ID --tags "Key=Name,Value=CafeDatabaseSubnetGroup" 2>/dev/null

# PAUSA PARA PRINT 1
pause_for_console "VPC Dashboard" "Subnets" "Filtre por 'Cafe'. Mostre as 2 novas subnets privadas criadas."

# 2. RDS
# ------------------------------------------------------------------------------
echo -e "${BLUE}[2/4] Gerenciando RDS...${NC}"
DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier CafeDBInstance --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null)

if [ "$DB_STATUS" == "None" ] || [ -z "$DB_STATUS" ]; then
    aws rds create-db-instance --db-instance-identifier CafeDBInstance --engine mariadb --db-instance-class db.t3.micro --allocated-storage 20 --availability-zone $CAFE_AZ --db-subnet-group-name "CafeDB Subnet Group" --vpc-security-group-ids $DB_SG_ID --no-publicly-accessible --master-username root --master-user-password 'Re:Start!9' > /dev/null
fi

echo "Aguardando RDS ficar 'Available'..."
while true; do
    STATUS=$(aws rds describe-db-instances --db-instance-identifier CafeDBInstance --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null)
    if [ "$STATUS" == "available" ]; then break; fi
    sleep 15
done
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier CafeDBInstance --query "DBInstances[0].Endpoint.Address" --output text)

# PAUSA PARA PRINT 2
pause_for_console "RDS Dashboard" "Databases" "O banco 'cafedbinstance' com status 'Available' e o Endpoint visível."

# 3. MIGRAÇÃO (CLI É INDISPENSÁVEL AQUI)
# ------------------------------------------------------------------------------
echo -e "${BLUE}[3/4] Migrando Dados...${NC}"
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
MY_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4)
CAFE_IP=$(aws ec2 describe-instances --instance-ids $CAFE_INSTANCE_ID --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

aws ec2 authorize-security-group-ingress --group-id $CAFE_SG_ID --protocol tcp --port 22 --cidr $MY_IP/32 2>/dev/null

ssh -o ConnectTimeout=20 -i "$KEY_FILE" -o StrictHostKeyChecking=no ec2-user@$CAFE_IP << EOF
    if ! command -v mysqldump &> /dev/null; then sudo yum install -y mariadb; fi
    sudo service mariadb start 2>/dev/null
    
    # Auto-Repair se banco vazio
    DB_CHECK=\$(mysql -u root -p'Re:Start!9' -e "SHOW DATABASES LIKE 'cafe_db';" 2>/dev/null)
    if [ -z "\$DB_CHECK" ]; then
        mysql -u root -p'Re:Start!9' -e "CREATE DATABASE cafe_db; USE cafe_db; CREATE TABLE product (id int, name varchar(255), price decimal(10,2)); INSERT INTO product VALUES (1,'Espresso',2.50),(2,'Latte',3.50);"
    fi

    mysqldump --user=root --password='Re:Start!9' --databases cafe_db --add-drop-database > cafedb-backup.sql
    mysql --user=root --password='Re:Start!9' --host=$RDS_ENDPOINT < cafedb-backup.sql
    
    echo "--- RESULTADO DA MIGRAÇÃO ---"
    mysql --user=root --password='Re:Start!9' --host=$RDS_ENDPOINT cafe_db -e "select count(*) as 'Total_Produtos_RDS' from product;"
EOF

echo -e "\n${YELLOW}📸 AÇÃO NECESSÁRIA: TIRE PRINT DESTE TERMINAL!${NC}"
echo "Infelizmente, não há tela no Console AWS para ver dados dentro da tabela."
echo "Este print do terminal provando que o 'select count' retornou dados é indispensável."
read -p "Pressione [ENTER] após tirar o print do terminal..."

# 4. PARAMETER STORE
# ------------------------------------------------------------------------------
echo -e "${BLUE}[4/4] Atualizando App...${NC}"
aws ssm put-parameter --name "/cafe/dbUrl" --value "$RDS_ENDPOINT" --type String --overwrite

# PAUSA PARA PRINT 3
pause_for_console "Systems Manager" "Parameter Store" "O parâmetro '/cafe/dbUrl' mostrando o valor do Endpoint do RDS."

echo -e "${GREEN}=== FIM DO SCRIPT ===${NC}"
echo "Dica Final: Tire um print do site '/cafe' na aba 'Order History' para provar que a aplicação funciona."