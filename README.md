# Hospedagem_cloudflare
```bash
bash <(curl -sSL https://raw.githubusercontent.com/macbservices/Hospedagem_cloudflare/main/install.sh)


Executar na ordem um por um:

1- sudo chown -R www-data:www-data /var/www/html
2- sudo find /var/www/html -type d -exec chmod 755 {} \;
3- sudo find /var/www/html -type f -exec chmod 644 {} \;
4- sudo systemctl restart apache2
