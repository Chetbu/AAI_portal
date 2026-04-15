FROM nginx:1.27-alpine

RUN apk add --no-cache curl jq

RUN rm /etc/nginx/conf.d/default.conf

COPY portal/nginx.conf /etc/nginx/conf.d/portal.conf
COPY portal/index.html /usr/share/nginx/html/index.html
COPY portal/config.json.template /etc/portal/config.json.template
COPY portal/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY portal/entrypoint.sh /entrypoint.sh
COPY docs/guides/ /usr/share/nginx/html/guides/

RUN curl -fsSL https://cdn.jsdelivr.net/npm/marked@9.1.6/marked.min.js \
    -o /usr/share/nginx/html/marked.min.js

RUN chmod +x /entrypoint.sh /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
