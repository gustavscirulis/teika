# Privacy Policy — Teika

**Last updated: 26 August 2026**

Teika processes recordings and notes on your devices. It does not upload your
recordings, transcripts, or notes, and it does not use a remote AI inference
service. A user-approved speech-model download connects to Hugging Face, Inc.
and exposes the limited connection information described below.

## Your voice

When you record on your iPhone, audio is captured into memory, transcribed on
the iPhone, and then discarded. It is not written to persistent storage or
uploaded.

Recording on an Apple Watch works differently because the watch cannot run the
speech recogniser itself. The recording is written to a temporary file on the
watch and transferred through Apple's WatchConnectivity service to your paired
iPhone. If processing is interrupted, the iPhone may keep the file until local
transcription can resume. Teika deletes the temporary files after processing.
Watch recordings are not uploaded and do not leave your paired devices.

## Your notes

Transcriptions are saved in Teika's local storage on your iPhone. They are not
synced to a Teika server, and Teika's developer cannot read them.

iOS may include the app's local notes in your personal iCloud or computer device
backup if you enable device backups. That backup is managed by you and Apple;
Teika's developer cannot access it. You can exclude Teika in your iCloud backup
settings. The downloaded speech model is excluded from device backups.

## Your clipboard

Teika automatically writes each completed transcription to the system
clipboard so you can paste it into another app. Teika never reads from the
clipboard. Other apps may be able to read clipboard content under the controls
provided by iOS.

## Model download and connection data

Teika needs a speech-recognition model of approximately 0.5 GB. The app explains
the download and asks for permission before starting it. Choosing **Not Now**
does not begin a download.

If you approve the download, Teika connects to Hugging Face, Inc. to retrieve
the public model files. Like other Internet services, Hugging Face receives the
IP address used for the connection, which can indicate approximate location,
the request and session time, and basic device and software information. Teika
does not attach recordings, transcripts, notes, account details, advertising
identifiers, or other user content to those requests. Teika's developer does
not receive the connection information.

Hugging Face may use connection information to deliver, secure, monitor, and
improve its service. Hugging Face describes its handling, retention,
international processing, safeguards, and user rights in its
[privacy policy](https://huggingface.co/privacy). Teika uses Hugging Face only on
the basis that it provides the same or equivalent protection for this connection
information through those commitments and applicable data-protection
obligations. The model host is not used to perform transcription: after the
model is present, speech recognition runs on your iPhone and works without an
Internet connection. Reinstalling Teika or removing its model can require
another approved download.

## Permissions

**Microphone.** Used to capture speech for transcription on your devices. The
iPhone and Apple Watch request permission separately when you try to record.

**Motion.** Used only to tilt the decorative animation as you move the device.
Motion data is not stored or transmitted. Declining permission only disables
the tilt effect.

## Analytics, advertising, and tracking

Teika contains no analytics, advertising, attribution, or crash-reporting SDK.
It does not access the Advertising Identifier and does not track you across apps
or websites. Hugging Face is contacted only for a model download you approve,
as described above.

## Support messages

If you email Teika support, the email provider delivers your address, message,
and anything you choose to include to Teika's developer. That information is
used only to respond to and resolve your request. It is retained in the support
mailbox only as long as reasonably needed for support, security, and legal
recordkeeping, and can be deleted on request unless retention is legally
required.

## Children

Teika does not ask for an age, create accounts, or intentionally collect
information from children. The limited model-download connection information is
handled in the same way for every user.

## Your choices and rights

Your notes are on your iPhone. Swipe a note in the list to delete it, or delete
the app to remove its notes and downloaded model from that device. Existing
iCloud or computer backups are controlled separately by you and Apple and may
retain notes until the backup is removed or replaced. Temporary Watch recordings
are removed after processing as described above.

You can decline the model download and no connection to Hugging Face will be
made by Teika. Once an approved download request has completed, deleting Teika
does not delete connection records already held by Hugging Face. Requests
concerning that information should be made using the contact and rights
information in Hugging Face's privacy policy. You can contact Teika to ask about
or delete support correspondence.

## Changes to this policy

If this policy changes, the updated version will be posted at this address with
a new effective date.

## Contact

gustavs.cirulis@gmail.com
