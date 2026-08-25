FROM alpine:3.20
RUN apk add --no-cache git git-daemon python3
ENV GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=*
COPY server.py /server.py
EXPOSE 8080
CMD ["python3", "/server.py"]
