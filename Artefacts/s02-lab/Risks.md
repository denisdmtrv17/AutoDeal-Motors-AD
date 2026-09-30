# Two Main Risks

## 1. Old Apache Version
The server uses Apache 2.4.49, which is outdated and has known security problems. An attacker can detect the version with Nmap and try to use these vulnerabilities.

## 2. Discoverable Web Resources
ffuf found different files and folders on the web server. This can give an attacker useful information about the website and possible weak points.

MITRE ATT&CK: **T1592 - Gather victim host information**

MITRE ATT&CK: **T1595 – Active scaning**
