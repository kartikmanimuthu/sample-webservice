#!/bin/bash

# Deployment script for Packer AMI to Auto Scaling Group
# This script updates the launch template with a new AMI and triggers rolling deployment

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Default values
AWS_REGION=${AWS_DEFAULT_REGION:-"ap-south-1"}
PROJECT_NAME=${PROJECT_NAME:-"packer-imagebuilder-poc"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
LAUNCH_TEMPLATE_ID=""
ASG_NAME=""
AMI_ID=""
WAIT_FOR_COMPLETION=false
TIMEOUT=1800  # 30 minutes default timeout

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy a new AMI to Auto Scaling Group via Launch Template update

Options:
    -a, --ami-id AMI_ID              AMI ID to deploy (required)
    -l, --launch-template-id ID      Launch Template ID (required)
    -g, --asg-name NAME              Auto Scaling Group name (required)
    -r, --region REGION              AWS region (default: $AWS_REGION)
    -p, --project-name NAME          Project name (default: $PROJECT_NAME)
    -e, --environment ENV            Environment (default: $ENVIRONMENT)
    -w, --wait                       Wait for deployment completion
    -t, --timeout SECONDS            Timeout in seconds (default: $TIMEOUT)
    -h, --help                       Show this help message

Environment Variables:
    AWS_DEFAULT_REGION               AWS region
    PROJECT_NAME                     Project name
    ENVIRONMENT                      Environment name
    LAUNCH_TEMPLATE_ID               Launch Template ID
    ASG_NAME                         Auto Scaling Group name

Examples:
    $0 -a ami-12345678 -l lt-abcdef123 -g my-asg
    $0 --ami-id ami-12345678 --launch-template-id lt-abcdef123 --asg-name my-asg --wait
    
    # Using environment variables
    export LAUNCH_TEMPLATE_ID=lt-abcdef123
    export ASG_NAME=my-asg
    $0 -a ami-12345678

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--ami-id)
            AMI_ID="$2"
            shift 2
            ;;
        -l|--launch-template-id)
            LAUNCH_TEMPLATE_ID="$2"
            shift 2
            ;;
        -g|--asg-name)
            ASG_NAME="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -p|--project-name)
            PROJECT_NAME="$2"
            shift 2
            ;;
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -w|--wait)
            WAIT_FOR_COMPLETION=true
            shift
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Use environment variables if not provided via command line
LAUNCH_TEMPLATE_ID=${LAUNCH_TEMPLATE_ID:-$LAUNCH_TEMPLATE_ID}
ASG_NAME=${ASG_NAME:-$ASG_NAME}

# Validate required parameters
if [[ -z "$AMI_ID" ]]; then
    log_error "AMI ID is required. Use -a or --ami-id"
    usage
    exit 1
fi

if [[ -z "$LAUNCH_TEMPLATE_ID" ]]; then
    log_error "Launch Template ID is required. Use -l or --launch-template-id or set LAUNCH_TEMPLATE_ID environment variable"
    usage
    exit 1
fi

if [[ -z "$ASG_NAME" ]]; then
    log_error "Auto Scaling Group name is required. Use -g or --asg-name or set ASG_NAME environment variable"
    usage
    exit 1
fi

# Check if required tools are installed
check_dependencies() {
    local missing_deps=()
    
    if ! command -v aws &> /dev/null; then
        missing_deps+=("aws-cli")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install the missing dependencies and try again"
        exit 1
    fi
}

# Set AWS region
export AWS_DEFAULT_REGION=$AWS_REGION

log_info "Starting deployment process..."
log_info "Parameters:"
log_info "  AMI ID: $AMI_ID"
log_info "  Launch Template ID: $LAUNCH_TEMPLATE_ID" 
log_info "  Auto Scaling Group: $ASG_NAME"
log_info "  AWS Region: $AWS_REGION"
log_info "  Project: $PROJECT_NAME"
log_info "  Environment: $ENVIRONMENT"
log_info "  Wait for completion: $WAIT_FOR_COMPLETION"

# Check dependencies
check_dependencies

# Get current IAM identity
log_info "Checking AWS credentials..."
CALLER_IDENTITY=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "Unable to get caller identity")
log_info "Current IAM identity: $CALLER_IDENTITY"

# Verify AMI exists and is available
log_info "Verifying AMI exists and is available..."
AMI_STATE=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --query 'Images[0].State' \
    --output text 2>/dev/null || echo "null")

if [[ "$AMI_STATE" != "available" ]]; then
    log_error "AMI $AMI_ID is not available (state: $AMI_STATE)"
    exit 1
fi
log_success "AMI $AMI_ID is available for deployment"

# Verify Launch Template access
log_info "Verifying launch template access..."
LAUNCH_TEMPLATE_NAME=$(aws ec2 describe-launch-templates \
    --launch-template-ids "$LAUNCH_TEMPLATE_ID" \
    --query 'LaunchTemplates[0].LaunchTemplateName' \
    --output text 2>/dev/null || echo "null")

if [[ "$LAUNCH_TEMPLATE_NAME" == "null" ]]; then
    log_error "Cannot access launch template $LAUNCH_TEMPLATE_ID"
    log_error "Required permissions: ec2:DescribeLaunchTemplates, ec2:CreateLaunchTemplateVersion"
    exit 1
fi
log_success "Launch template access verified: $LAUNCH_TEMPLATE_NAME"

# Verify Auto Scaling Group access
log_info "Verifying Auto Scaling Group access..."
ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].AutoScalingGroupName' \
    --output text 2>/dev/null || echo "null")

if [[ "$ASG_EXISTS" != "$ASG_NAME" ]]; then
    log_error "Cannot access Auto Scaling Group $ASG_NAME"
    log_error "Required permissions: autoscaling:DescribeAutoScalingGroups, autoscaling:UpdateAutoScalingGroup"
    exit 1
fi
log_success "Auto Scaling Group access verified"

# Get current launch template version
log_info "Getting current launch template version..."
CURRENT_VERSION=$(aws ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --query 'LaunchTemplateVersions[0].VersionNumber' \
    --output text)

if [[ -z "$CURRENT_VERSION" ]] || [[ "$CURRENT_VERSION" == "None" ]]; then
    log_error "Failed to get current launch template version"
    exit 1
fi
log_info "Current launch template version: $CURRENT_VERSION"

# Create new launch template version with new AMI
log_info "Creating new launch template version with AMI: $AMI_ID"
NEW_VERSION=$(aws ec2 create-launch-template-version \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --source-version "$CURRENT_VERSION" \
    --launch-template-data "{\"ImageId\":\"$AMI_ID\"}" \
    --query 'LaunchTemplateVersion.VersionNumber' \
    --output text 2>&1)

if [[ $? -ne 0 ]]; then
    log_error "Failed to create new launch template version"
    log_error "AWS CLI output: $NEW_VERSION"
    log_error "Required permissions: ec2:CreateLaunchTemplateVersion"
    exit 1
fi

if [[ -z "$NEW_VERSION" ]] || [[ "$NEW_VERSION" == "None" ]]; then
    log_error "Invalid launch template version returned: $NEW_VERSION"
    exit 1
fi
log_success "Created new launch template version: $NEW_VERSION"

# Update Auto Scaling Group to use new launch template version
log_info "Updating Auto Scaling Group to use new launch template version..."
UPDATE_RESULT=$(aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=$LAUNCH_TEMPLATE_ID,Version=$NEW_VERSION" 2>&1)

if [[ $? -ne 0 ]]; then
    log_error "Failed to update Auto Scaling Group"
    log_error "AWS CLI output: $UPDATE_RESULT"
    log_error "Common causes:"
    log_error "  1. Missing IAM permission: autoscaling:UpdateAutoScalingGroup"
    log_error "  2. Missing IAM permission: iam:PassRole (for launch template)"
    log_error "  3. Missing IAM permission: ec2:RunInstances (for launch template)"
    log_error "Current IAM identity: $CALLER_IDENTITY"
    exit 1
fi
log_success "Auto Scaling Group updated successfully"

# Verify the update was successful
log_info "Verifying Auto Scaling Group update..."
CURRENT_LT_VERSION=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].LaunchTemplate.Version' \
    --output text)

if [[ "$CURRENT_LT_VERSION" != "$NEW_VERSION" ]]; then
    log_warning "ASG launch template version mismatch"
    log_warning "Expected: $NEW_VERSION, Actual: $CURRENT_LT_VERSION"
else
    log_success "ASG successfully updated to use launch template version $NEW_VERSION"
fi

# Start instance refresh for rolling deployment
log_info "Starting instance refresh for rolling deployment..."
REFRESH_ID=$(aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG_NAME" \
    --preferences '{
        "InstanceWarmup": 300,
        "MinHealthyPercentage": 50,
        "CheckpointDelay": 600,
        "CheckpointPercentages": [50, 100]
    }' \
    --query 'InstanceRefreshId' \
    --output text)

if [[ -z "$REFRESH_ID" ]] || [[ "$REFRESH_ID" == "null" ]]; then
    log_error "Failed to start instance refresh"
    exit 1
fi
log_success "Instance refresh started with ID: $REFRESH_ID"

# Save deployment info
DEPLOYMENT_FILE="deployment_$(date +%Y%m%d_%H%M%S).env"
cat > "$DEPLOYMENT_FILE" << EOF
REFRESH_ID=$REFRESH_ID
AMI_ID=$AMI_ID
NEW_VERSION=$NEW_VERSION
LAUNCH_TEMPLATE_ID=$LAUNCH_TEMPLATE_ID
ASG_NAME=$ASG_NAME
DEPLOYMENT_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROJECT_NAME=$PROJECT_NAME
ENVIRONMENT=$ENVIRONMENT
AWS_REGION=$AWS_REGION
EOF

log_success "Deployment information saved to: $DEPLOYMENT_FILE"

# Wait for completion if requested
if [[ "$WAIT_FOR_COMPLETION" == "true" ]]; then
    log_info "Waiting for instance refresh to complete (timeout: ${TIMEOUT}s)..."
    
    START_TIME=$(date +%s)
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
        
        if [[ $ELAPSED_TIME -ge $TIMEOUT ]]; then
            log_error "Timeout reached waiting for instance refresh completion"
            exit 1
        fi
        
        REFRESH_STATUS=$(aws autoscaling describe-instance-refreshes \
            --auto-scaling-group-name "$ASG_NAME" \
            --instance-refresh-ids "$REFRESH_ID" \
            --query 'InstanceRefreshes[0].Status' \
            --output text)
        
        PERCENTAGE_COMPLETE=$(aws autoscaling describe-instance-refreshes \
            --auto-scaling-group-name "$ASG_NAME" \
            --instance-refresh-ids "$REFRESH_ID" \
            --query 'InstanceRefreshes[0].PercentageComplete' \
            --output text)
        
        log_info "Instance refresh status: $REFRESH_STATUS (${PERCENTAGE_COMPLETE}% complete)"
        
        case "$REFRESH_STATUS" in
            "Successful")
                log_success "Instance refresh completed successfully!"
                break
                ;;
            "Failed"|"Cancelled")
                log_error "Instance refresh failed with status: $REFRESH_STATUS"
                exit 1
                ;;
            "InProgress"|"Pending")
                sleep 30
                ;;
            *)
                log_warning "Unknown refresh status: $REFRESH_STATUS"
                sleep 30
                ;;
        esac
    done
fi

log_success "Deployment completed successfully!"
log_info "Summary:"
log_info "  - AMI ID: $AMI_ID"
log_info "  - Launch Template Version: $NEW_VERSION"
log_info "  - Instance Refresh ID: $REFRESH_ID"
log_info "  - Deployment file: $DEPLOYMENT_FILE"

# CLI usage examples
cat << EOF

CLI Usage Examples:
==================

1. Basic deployment:
   ./deploy.sh -a $AMI_ID -l $LAUNCH_TEMPLATE_ID -g $ASG_NAME

2. Deploy and wait for completion:
   ./deploy.sh -a $AMI_ID -l $LAUNCH_TEMPLATE_ID -g $ASG_NAME --wait

3. Deploy with custom timeout:
   ./deploy.sh -a $AMI_ID -l $LAUNCH_TEMPLATE_ID -g $ASG_NAME --wait --timeout 3600

4. Using environment variables:
   export LAUNCH_TEMPLATE_ID=$LAUNCH_TEMPLATE_ID
   export ASG_NAME=$ASG_NAME
   ./deploy.sh -a $AMI_ID

5. Check instance refresh status:
   aws autoscaling describe-instance-refreshes --auto-scaling-group-name $ASG_NAME

6. Cancel instance refresh (if needed):
   aws autoscaling cancel-instance-refresh --auto-scaling-group-name $ASG_NAME

EOF
