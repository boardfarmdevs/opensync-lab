# local-noc: plain-TCP OpenSync cloud stand-in (see noc.py). Standard library only.
FROM python:3.12-slim
COPY noc.py mesh.py topology.py noc-ctl /opt/local-noc/
COPY webui /opt/local-noc/webui
RUN chmod 0755 /opt/local-noc/noc.py /opt/local-noc/noc-ctl \
    && ln -s /opt/local-noc/noc-ctl /usr/local/bin/noc-ctl
VOLUME /var/lib/local-noc
# redirector, controller, web UI
EXPOSE 6640 6641 8640
ENTRYPOINT ["python3", "/opt/local-noc/noc.py"]
