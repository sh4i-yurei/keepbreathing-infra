import smtplib
import ssl
import sys
from email.message import EmailMessage
from pathlib import Path


mode = sys.argv[1]
try:
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    with smtplib.SMTP("mailpit.staging", 1025, timeout=10) as smtp:
        smtp.starttls(context=context)
        if mode == "login":
            smtp.login("staging", Path("/t/pw").read_text())
        message = EmailMessage()
        message["From"] = "staging@example.invalid"
        message["To"] = "recipient@example.invalid"
        message["Subject"] = "Staging contact test"
        message.set_content("Staging contact test")
        smtp.send_message(message)
    print(f"{mode}: SENT")
except Exception as error:
    print(f"{mode}: {type(error).__name__}: {error}")
