FROM nginx:1.27-alpine

RUN apk add --no-cache curl jq

RUN rm /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/conf.d/portal.conf
COPY index.html /usr/share/nginx/html/index.html
COPY config.json.template /etc/portal/config.json.template
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
