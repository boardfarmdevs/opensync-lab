# local-noc: plain-TCP OpenSync cloud stand-in (see noc.py). Standard library only.
FROM python:3.12-slim
COPY noc.py /usr/local/bin/local-noc
COPY mesh.py /usr/local/bin/mesh.py
COPY noc-ctl /usr/local/bin/noc-ctl
RUN chmod 0755 /usr/local/bin/local-noc /usr/local/bin/noc-ctl
VOLUME /var/lib/local-noc
EXPOSE 6640 6641
ENTRYPOINT ["/usr/local/bin/local-noc"]
