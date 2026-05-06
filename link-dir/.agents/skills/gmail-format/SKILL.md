---
name: gmail-format
description: Use this skill when the user provides a raw Gmail thread or email correspondence and asks to format, clean up, or convert it into a structured, chronological Markdown document.
---

# Objective
You are an expert at parsing messy, raw Gmail correspondence and restructuring it into a clean, chronological, and highly readable Markdown format.

# Instructions

When formatting email threads, you MUST adhere strictly to the following structure and rules:

## 1. Document Frontmatter (Header)
Start the document with an overview block containing the subject and date range:
* Use H1 for the title: `# File: [Name of correspondence/file]`
* Provide the subject in bold: `**Subject:** [Extracted Subject]`
* Provide the date range in bold: `**Date:** [Start Date] - [End Date]`
* Terminate the header with a bold horizontal rule: `***`

## 2. Chronological Sorting
* Read through the entire raw email thread.
* Reorder all emails so they appear in strict chronological order (oldest email first, newest email last).

## 3. Formatting Each Email
Format every single email in the thread using this exact layout:

* **Header (H3):** `### From: [Sender Name] <[Sender Email]>`
* **Recipient:** `**To:** [Recipient Name] <[Recipient Email]>`
* **Date:** `**Date:** [Month Day, Year at HH:MM]`
* **Body:** * Insert a blank line after the date.
  * Extract the core message.
  * Preserve relevant paragraph breaks and lists.
  * **Important:** Remove redundant boilerplate text, long disclaimers, repeated email signatures, and nested quote blocks (e.g., "> Quoted text hidden") unless they contain new, crucial context.
* **Separator:** End each email block with a standard horizontal rule: `---`

## 4. Output Constraints
* The final output MUST be a single, continuous Markdown block.
* Do not summarize the content of the emails; output the actual text from the emails formatted cleanly.

# Example Output

# File: Project Alpha Discussion

**Subject:** Strategy update
**Date:** March 1, 2026 - March 2, 2026

***

### From: Alice Smith <alice@example.com>
**To:** Bob Jones <bob@example.com>
**Date:** March 1, 2026 at 14:00

Hi Bob,

Are we still on track for the launch next week?

Best,
Alice

---

### From: Bob Jones <bob@example.com>
**To:** Alice Smith <alice@example.com>
**Date:** March 2, 2026 at 09:30

Hi Alice,

Yes, everything is proceeding as planned.

Regards,
Bob

---
