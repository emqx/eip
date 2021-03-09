# EMQ X Improvement Proposals (EIP)

This repository contains the EMQ X Improvement Proposals (EIPs), to documentation
the ideas, designs, or implement details of new features. All the EIPs are in
Markdown (`*.md`) format.

New EIPs should first go to the `active` directory by creating a pull request
and ask for an approval. After the feature is implemented it will be put into
the `implemented` directory.

Before submitting an EIP, please read the
[0000-proposal-template](active/0000-proposal-template.md), which is a template
demonstrating the format of EIPs.

## Creating UML diagrams

It is possible to add UML diagrams using [PlantUML](https://plantuml.com/).
In order to do this, create a directory called `active/XXXX-assets` (replace
`XXXX` with the EIP number), and put the files there. All files should have
`uml` extention.

Then run `make` to generate the images.
