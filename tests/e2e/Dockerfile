# Test image: end-to-end test runner and webhook receiver (Python standard library only).
# The health check of the receiver is defined in docker-compose.yml because the same image
# also runs the test itself, which does not listen on a port.
FROM python:3.14-alpine@sha256:f6a589d43c42b9e7f7dc67a12d37132491f362859a5d750607710cc56da3bc72

RUN adduser -D -H -u 10001 e2e

WORKDIR /e2e

COPY receiver.py test_e2e.py testpdf.py ./

USER 10001:10001

EXPOSE 8080

CMD ["python", "-I", "receiver.py"]

# The receiver health check lives in docker-compose.yml (this image also runs the test).
HEALTHCHECK NONE
