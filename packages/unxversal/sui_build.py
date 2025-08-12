#!/usr/bin/env python3

import sys
import subprocess
import re
from collections import defaultdict, OrderedDict

# --- ANSI Color Codes for better readability ---
class Colors:
    RESET = '\033[0m'
    FILE = '\033[1;36m'      # Bold Cyan
    ERROR_HEADER = '\033[1;31m' # Bold Red
    WARNING_HEADER = '\033[1;33m' # Bold Yellow
    DIVIDER = '\033[2;37m'      # Dim White/Gray

def main():
    """
    Executes `sui move build`, captures its output, and reprints it
    organized by file, with errors appearing before warnings.
    """
    try:
        # Execute the build command. We redirect stderr to stdout to process all
        # output in the correct chronological order from a single stream.
        result = subprocess.run(
            ['sui', 'move', 'build'],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding='utf-8'
        )
        full_output = result.stdout
        exit_code = result.returncode

    except FileNotFoundError:
        print(f"{Colors.ERROR_HEADER}Error: 'sui' command not found.{Colors.RESET}")
        print("Please ensure the Sui CLI is installed and in your system's PATH.")
        sys.exit(1)

    # --- Data structures to hold the organized output ---
    # Stores messages that aren't errors/warnings (e.g., "UPDATING GIT...")
    preamble_lines = []
    # A dictionary to group messages: { "filepath": {"errors": [...], "warnings": [...]}}
    messages_by_file = defaultdict(lambda: {"errors": [], "warnings": []})
    # An ordered dictionary used as a set to remember the order files appear in
    files_in_order = OrderedDict()
    # The final "Failed to build..." message, to be printed at the very end
    final_message = ""

    # --- Parse the captured output ---
    lines = iter(full_output.splitlines())
    for line in lines:
        is_error = line.startswith('error[')
        is_warning = line.startswith('warning[')

        if is_error or is_warning:
            # This is the start of a multi-line message block.
            # We'll read all its lines until we hit a blank line.
            current_block = [line]
            try:
                # The `next(lines)` will raise StopIteration at the end of the file
                while (next_line := next(lines)).strip() != "":
                    current_block.append(next_line)
            except StopIteration:
                pass # Reached the end of the output, block is finished.
            
            full_message = "\n".join(current_block)

            # Extract the filepath using a regular expression
            match = re.search(r"┌─\s*([^:]+):\d+", full_message)
            if match:
                filepath = match.group(1)
                files_in_order[filepath] = True # Add to our ordered set of files
                if is_error:
                    messages_by_file[filepath]['errors'].append(full_message)
                else:
                    messages_by_file[filepath]['warnings'].append(full_message)
            else:
                # This should not happen for a well-formed error/warning, but just in case
                preamble_lines.append(full_message)

        elif "Failed to build Move modules" in line:
            final_message = line
        else:
            # This is a standard progress line
            if line.strip():
                preamble_lines.append(line)

    # --- Print the organized results ---
    if preamble_lines:
        print("\n".join(preamble_lines))

    divider = f"{Colors.DIVIDER}{'=' * 80}{Colors.RESET}"

    for filepath in files_in_order:
        data = messages_by_file[filepath]
        has_errors = bool(data['errors'])
        has_warnings = bool(data['warnings'])

        if has_errors or has_warnings:
            print(f"\n{divider}")
            print(f"{Colors.FILE}File: {filepath}{Colors.RESET}")
            print(divider)

        if has_errors:
            print(f"{Colors.ERROR_HEADER}  ERRORS{Colors.RESET}")
            print("\n\n".join(data['errors']))
            if has_warnings:
                print() # Add a blank line for spacing

        if has_warnings:
            print(f"{Colors.WARNING_HEADER}  WARNINGS{Colors.RESET}")
            print("\n\n".join(data['warnings']))

    if final_message:
        print(f"\n{divider}")
        print(f"{Colors.ERROR_HEADER}{final_message}{Colors.RESET}")

    sys.exit(exit_code)


if __name__ == "__main__":
    main()