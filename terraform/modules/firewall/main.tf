# Firewall de borde para los nodos de DOKS. Única entrada pública: los
# puertos de var.public_ports (80/443), pensados para el futuro Ingress
# del cluster. Los 6 backends (hsm-service, certificate-service,
# signing-service, identification-service, verification-service,
# audit-service) nunca quedan expuestos acá — solo hablan entre sí dentro
# del cluster (ClusterIP) y hacia afuera a través de api-gateway, que es
# el único que termina detrás del Ingress en 80/443.
resource "digitalocean_firewall" "doks_ingress" {
  name = var.name
  tags = [var.target_tag]

  dynamic "inbound_rule" {
    for_each = var.public_ports
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.value
      source_addresses = ["0.0.0.0/0", "::/0"]
    }
  }

  # Tráfico intra-cluster (pods, kube-proxy, kubelet, health checks entre
  # nodos): acotado a droplets que pertenecen a ESTE cluster DOKS, no a
  # "todo Internet" ni a "todo lo que tenga este tag".
  inbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    source_kubernetes_ids = [var.doks_cluster_id]
  }

  inbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    source_kubernetes_ids = [var.doks_cluster_id]
  }

  inbound_rule {
    protocol              = "icmp"
    source_kubernetes_ids = [var.doks_cluster_id]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
