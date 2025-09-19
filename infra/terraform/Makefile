SHELL := /bin/bash

TF := terraform
REGION ?= us-east-1
CLUSTER ?= bedrock-eks

.PHONY: init plan apply destroy kubeconfig

init:
	cd $(PWD) && $(TF) init

plan:
	$(TF) plan -var="region=$(REGION)" -var="cluster_name=$(CLUSTER)"

apply:
	$(TF) apply -var="region=$(REGION)" -var="cluster_name=$(CLUSTER)"

destroy:
	$(TF) destroy -var="region=$(REGION)" -var="cluster_name=$(CLUSTER)"

kubeconfig:
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER) ${AWS_PROFILE:+--profile $$AWS_PROFILE}

