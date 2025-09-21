######################################################################
# Kubernetes app deployments without Helm (v2)
# This file recreates the catalog, cart, orders, and ui components
# using the Kubernetes provider directly.
#
# IMPORTANT: Do not apply this alongside the Helm-based kubernetes.tf,
# as it uses the same Kubernetes object names and will conflict.
######################################################################

########################
# EKS readiness (v2)
########################
resource "null_resource" "eks_ready_v2" {
  depends_on = [module.eks]
}

########################
# Namespace
########################
resource "kubernetes_namespace" "retail" {
  provider = kubernetes.cluster

  metadata {
    name = "retail"
  }
}

########################
# Catalog service
########################

# Config for catalog persistence
resource "kubernetes_config_map" "catalog" {
  provider = kubernetes.cluster

  metadata {
    name      = "catalog"
    namespace = kubernetes_namespace.retail.metadata[0].name
  }

  data = {
    RETAIL_CATALOG_PERSISTENCE_PROVIDER = "mysql"
    # Endpoint must include host:port for the app
    RETAIL_CATALOG_PERSISTENCE_ENDPOINT = "${module.catalog_rds_v2.cluster_endpoint}:${module.catalog_rds_v2.cluster_port}"
    RETAIL_CATALOG_PERSISTENCE_DB_NAME  = module.catalog_rds_v2.cluster_database_name
  }

  depends_on = [
    kubernetes_namespace.retail,
    null_resource.eks_ready_v2,
    module.catalog_rds_v2,
  ]
}

# Secret for catalog DB credentials
resource "kubernetes_secret" "catalog_db" {
  provider = kubernetes.cluster

  metadata {
    name      = "catalog-db"
    namespace = kubernetes_namespace.retail.metadata[0].name
  }

  data = {
    RETAIL_CATALOG_PERSISTENCE_USER     = module.catalog_rds_v2.cluster_master_username
    RETAIL_CATALOG_PERSISTENCE_PASSWORD = module.catalog_rds_v2.cluster_master_password
  }

  type = "Opaque"

  depends_on = [
    kubernetes_namespace.retail,
    null_resource.eks_ready_v2,
    module.catalog_rds_v2,
  ]
}

# ExternalName Service to resolve catalog-db to Aurora endpoint
resource "kubernetes_service" "catalog_db" {
  provider = kubernetes.cluster

  metadata {
    name      = "catalog-db"
    namespace = kubernetes_namespace.retail.metadata[0].name
  }

  spec {
    type          = "ExternalName"
    external_name = module.catalog_rds_v2.cluster_endpoint
  }

  depends_on = [
    kubernetes_namespace.retail,
    module.catalog_rds_v2,
  ]
}

# Deployment: catalog
resource "kubernetes_deployment" "catalog" {
  provider = kubernetes.cluster

  metadata {
    name      = "catalog"
    namespace = kubernetes_namespace.retail.metadata[0].name
    labels = {
      app = "catalog"
    }
    # Trigger rollout on ConfigMap-related values change
    annotations = {
      "catalog/config-endpoint" = "${module.catalog_rds_v2.cluster_endpoint}:${module.catalog_rds_v2.cluster_port}"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "catalog"
      }
    }

    template {
      metadata {
        labels = {
          app = "catalog"
        }
      }

      spec {
        # Wait until the DB endpoint is reachable before starting app
        init_container {
          name  = "wait-for-mysql"
          image = "busybox:1.36"
          env {
            name = "ENDPOINT"
            value_from {
              config_map_key_ref {
                name = kubernetes_config_map.catalog.metadata[0].name
                key  = "RETAIL_CATALOG_PERSISTENCE_ENDPOINT"
              }
            }
          }
          command = [
            "sh",
            "-c",
            "HOST=$(echo \"$ENDPOINT\" | cut -d: -f1); PORT=$(echo \"$ENDPOINT\" | cut -d: -f2); until nc -z \"$HOST\" \"$PORT\"; do echo waiting for mysql; sleep 5; done"
          ]
        }
        container {
          name  = "catalog"
          image = "public.ecr.aws/aws-containers/retail-store-sample-catalog:1.3.0"

          port {
            name           = "http"
            container_port = 8080
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.catalog.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret.catalog_db.metadata[0].name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map.catalog,
    kubernetes_secret.catalog_db,
  ]
}

# Service: catalog
resource "kubernetes_service" "catalog" {
  provider = kubernetes.cluster

  metadata {
    name      = "catalog"
    namespace = kubernetes_namespace.retail.metadata[0].name
    labels = {
      app = "catalog"
    }
  }

  spec {
    selector = {
      app = "catalog"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.catalog]
}

########################
# Cart service (with IRSA)
########################

# ServiceAccount for carts with IRSA annotation
resource "kubernetes_service_account" "carts_sa" {
  provider = kubernetes.cluster

  metadata {
    name      = "carts-sa"
    namespace = kubernetes_namespace.retail.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.cart_irsa.arn
    }
  }

  depends_on = [
    kubernetes_namespace.retail,
    aws_iam_role.cart_irsa,
    null_resource.eks_ready_v2,
  ]
}

# Config for carts persistence (DynamoDB)
resource "kubernetes_config_map" "carts" {
  provider = kubernetes.cluster

  metadata {
    name      = "carts"
    namespace = kubernetes_namespace.retail.metadata[0].name
  }

  data = {
    RETAIL_CART_PERSISTENCE_PROVIDER              = "dynamodb"
    RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME   = module.dynamodb_carts_v2.dynamodb_table_id
    RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE = "false"
  }

  depends_on = [
    kubernetes_namespace.retail,
    null_resource.eks_ready_v2,
    module.dynamodb_carts_v2,
  ]
}

# Deployment: carts
resource "kubernetes_deployment" "carts" {
  provider = kubernetes.cluster

  metadata {
    name      = "carts"
    namespace = kubernetes_namespace.retail.metadata[0].name
    labels = {
      app = "carts"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "carts"
      }
    }

    template {
      metadata {
        labels = {
          app = "carts"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.carts_sa.metadata[0].name

        container {
          name  = "carts"
          image = "public.ecr.aws/aws-containers/retail-store-sample-cart:1.3.0"

          port {
            name           = "http"
            container_port = 8080
          }

          readiness_probe {
            http_get {
              path = "/actuator/health/readiness"
              port = "http"
            }
            initial_delay_seconds = 10
          }

          env {
            name  = "JAVA_OPTS"
            value = "-XX:MaxRAMPercentage=75.0 -Djava.security.egd=file:/dev/urandom"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.carts.metadata[0].name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service_account.carts_sa,
    kubernetes_config_map.carts,
  ]
}

# Service: carts
resource "kubernetes_service" "carts" {
  provider = kubernetes.cluster

  metadata {
    name      = "carts"
    namespace = kubernetes_namespace.retail.metadata[0].name
    labels = {
      app = "carts"
    }
  }

  spec {
    selector = {
      app = "carts"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.carts]
}

########################
# Orders service
########################

# Config for orders (Postgres + RabbitMQ)
resource "kubernetes_config_map" "orders" {
  provider = kubernetes.cluster

  metadata {
    name      = "orders"
    namespace = kubernetes_namespace.retail.metadata[0].name
  }

  data = {
    RETAIL_ORDERS_MESSAGING_PROVIDER           = "rabbitmq"
    RETAIL_ORDERS_MESSAGING_RABBITMQ_ADDRESSES = aws_mq_broker.mq_v2.instances[0].endpoints[0]
    RETAIL_ORDERS_PERSISTENCE_PROVIDER         = "postgres"
    RETAIL_ORDERS_PERSISTENCE_ENDPOINT         = "${module.orders_rds_v2.cluster_endpoint}:${module.orders_rds_v2.cluster_port}"
    RETAIL_ORDERS_PERSISTENCE_NAME             = module.orders_rds_v2.cluster_database_name
  }

  depends_on = [
    kubernetes_namespace.retail,
    null_resource.eks_ready_v2,
    module.orders_rds_v2,
    aws_mq_broker.mq_v2,
  ]
}

# Secret for orders DB credentials
resource "kubernetes_secret" "orders_db" {
  provider = kubernetes.cluster

  metadata {
    name      = "orders-db"
    namespace = kubernetes_namespace.retail.metadata[0].name
  }

  data = {
    RETAIL_ORDERS_PERSISTENCE_USERNAME = module.orders_rds_v2.cluster_master_username
    RETAIL_ORDERS_PERSISTENCE_PASSWORD = module.orders_rds_v2.cluster_master_password
  }

  type = "Opaque"

  depends_on = [
    kubernetes_namespace.retail,
    null_resource.eks_ready_v2,
    module.orders_rds_v2,
  ]
}

# Secret for orders RabbitMQ auth
resource "kubernetes_secret" "orders_rabbitmq" {
  provider = kubernetes.cluster

  metadata {
    name      = "orders-rabbitmq"
    namespace = kubernetes_namespace.retail.metadata[0].name
  }

  data = {
    RETAIL_ORDERS_MESSAGING_RABBITMQ_USERNAME = local.mq_default_user_v2
    RETAIL_ORDERS_MESSAGING_RABBITMQ_PASSWORD = random_password.mq_password_v2.result
  }

  type = "Opaque"

  depends_on = [
    kubernetes_namespace.retail,
    null_resource.eks_ready_v2,
    aws_mq_broker.mq_v2,
  ]
}

# Deployment: orders
resource "kubernetes_deployment" "orders" {
  provider = kubernetes.cluster

  metadata {
    name      = "orders"
    namespace = kubernetes_namespace.retail.metadata[0].name
    labels = {
      app = "orders"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "orders"
      }
    }

    template {
      metadata {
        labels = {
          app = "orders"
        }
      }

      spec {
        container {
          name  = "orders"
          image = "public.ecr.aws/aws-containers/retail-store-sample-orders:1.3.0"

          port {
            name           = "http"
            container_port = 8080
          }

          readiness_probe {
            http_get {
              path = "/actuator/health/readiness"
              port = "http"
            }
            initial_delay_seconds = 10
          }

          env {
            name  = "JAVA_OPTS"
            value = "-XX:MaxRAMPercentage=75.0 -Djava.security.egd=file:/dev/urandom"
          }

          env_from {
            secret_ref {
              name = kubernetes_secret.orders_rabbitmq.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret.orders_db.metadata[0].name
            }
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.orders.metadata[0].name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map.orders,
    kubernetes_secret.orders_db,
    kubernetes_secret.orders_rabbitmq,
  ]
}

# Service: orders
resource "kubernetes_service" "orders" {
  provider = kubernetes.cluster

  metadata {
    name      = "orders"
    namespace = kubernetes_namespace.retail.metadata[0].name
    labels = {
      app = "orders"
    }
  }

  spec {
    selector = {
      app = "orders"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.orders]
}

########################
# UI service
########################

# Config for UI endpoints
resource "kubernetes_config_map" "ui" {
  provider = kubernetes.cluster

  metadata {
    name      = "ui"
    namespace = kubernetes_namespace.retail.metadata[0].name
  }

  data = {
    RETAIL_UI_ENDPOINTS_CATALOG = "http://catalog:80"
    RETAIL_UI_ENDPOINTS_CARTS   = "http://carts:80"
    RETAIL_UI_ENDPOINTS_ORDERS  = "http://orders:80"
  }

  depends_on = [
    kubernetes_namespace.retail,
    null_resource.eks_ready_v2,
  ]
}

# Deployment: ui
resource "kubernetes_deployment" "ui" {
  provider = kubernetes.cluster

  metadata {
    name      = "ui"
    namespace = kubernetes_namespace.retail.metadata[0].name
    labels = {
      app = "ui"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "ui"
      }
    }

    template {
      metadata {
        labels = {
          app = "ui"
        }
      }

      spec {
        container {
          name  = "ui"
          image = "public.ecr.aws/aws-containers/retail-store-sample-ui:1.3.0"

          port {
            name           = "http"
            container_port = 8080
          }

          readiness_probe {
            http_get {
              path = "/actuator/health/readiness"
              port = "http"
            }
            initial_delay_seconds = 10
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.ui.metadata[0].name
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_config_map.ui]
}

# Service: ui
resource "kubernetes_service" "ui" {
  provider = kubernetes.cluster

  metadata {
    name      = "ui"
    namespace = kubernetes_namespace.retail.metadata[0].name
    labels = {
      app = "ui"
    }
  }

  spec {
    selector = {
      app = "ui"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.ui]
}
