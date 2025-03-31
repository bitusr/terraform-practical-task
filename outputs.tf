output "url" {
  value = "http://${aws_elb.app.dns_name}"
}
