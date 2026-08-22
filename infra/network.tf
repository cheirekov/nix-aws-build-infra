resource "aws_vpc" "builder" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-vpc" }
}
resource "aws_internet_gateway" "builder" {
  vpc_id = aws_vpc.builder.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "builder" {
  count = min(3, length(data.aws_availability_zones.available.names))

  vpc_id                  = aws_vpc.builder.id
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = cidrsubnet(aws_vpc.builder.cidr_block, 8, count.index)
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-${data.aws_availability_zones.available.names[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.builder.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.builder.id
  }

  tags = { Name = "${var.project_name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.builder)
  subnet_id      = aws_subnet.builder[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "runner" {
  name        = "${var.project_name}-runner"
  description = "No ingress; HTTPS and DNS egress for ephemeral builders"
  vpc_id      = aws_vpc.builder.id

  egress {
    description = "HTTPS"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS UDP"
    protocol    = "udp"
    from_port   = 53
    to_port     = 53
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS TCP"
    protocol    = "tcp"
    from_port   = 53
    to_port     = 53
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-runner" }
}
