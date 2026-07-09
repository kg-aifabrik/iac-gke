# Outputs consumed by the deploy step (the workload connects to the instance via
# the Cloud SQL Auth Proxy using the connection name, and grants its identity the
# instance user).

output "instance_name" {
  description = "Full Cloud SQL instance name (includes the random suffix)."
  value       = google_sql_database_instance.this.name
}

output "connection_name" {
  description = "Instance connection name (project:region:instance) for the Cloud SQL Auth Proxy."
  value       = google_sql_database_instance.this.connection_name
}

output "private_ip_address" {
  description = "Private IP the instance is reachable at over the VPC."
  value       = google_sql_database_instance.this.private_ip_address
}

output "database_names" {
  description = "Databases created on the instance."
  value       = [for db in google_sql_database.this : db.name]
}
