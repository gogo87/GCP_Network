variable "project_id"{
    type = string
}

variable region{
    type = string
    default =  "us-central1"
}

variable front_cidr {}
variable back_cidr {}
variable DMZ_cidr {}
variable name {}