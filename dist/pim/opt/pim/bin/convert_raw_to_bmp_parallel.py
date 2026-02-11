#!/usr/bin/env python3
"""
Raw Image to BMP Converter - Auto Detection + Parallel Processing
Converts multiple raw images simultaneously for maximum speed

Usage:
    python convert_raw_to_bmp_parallel.py          # 1회 실행 (기본)
    python convert_raw_to_bmp_parallel.py --loop   # 루프 모드
    python convert_raw_to_bmp_parallel.py --loop --interval 2  # 2초 간격 루프
"""

import os
import sys
import math
import time
import signal
import argparse
import logging
import logging.handlers
import multiprocessing as mp
from pathlib import Path
import numpy as np
from PIL import Image

# ========== CONFIGURATION ==========
WATCH_DIR = "/dev/shm/capture/"
OUTPUT_DIR = "/dev/shm/capture/"
DELETE_RAW_AFTER_CONVERT = True

# Parallel processing settings
NUM_JOBS = 4  # Number of parallel conversions (adjust based on CPU cores)

# Loop mode settings
DEFAULT_LOOP_INTERVAL = 1.0  # seconds
# ===================================

# Add custom NOTICE log level (between INFO and WARNING)
NOTICE_LEVEL = 25  # Between INFO(20) and WARNING(30)
logging.addLevelName(NOTICE_LEVEL, 'NOTICE')

def notice(self, message, *args, **kwargs):
    if self.isEnabledFor(NOTICE_LEVEL):
        self._log(NOTICE_LEVEL, message, args, **kwargs)

logging.Logger.notice = notice

# Setup logger (local0 facility)
def setup_logger(app_name='raw2bmp'):
    logger = logging.getLogger(app_name)
    logger.setLevel(logging.DEBUG)

    # Clear existing handlers
    for handler in logger.handlers[:]:
        logger.removeHandler(handler)

    # Syslog handler (local0)
    try:
        # Try different syslog addresses
        syslog_addresses = ['/dev/log', ('localhost', 514)]
        syslog_handler = None

        for addr in syslog_addresses:
            try:
                syslog_handler = logging.handlers.SysLogHandler(
                    address=addr,
                    facility=logging.handlers.SysLogHandler.LOG_LOCAL0
                )
                syslog_handler.setLevel(logging.INFO)
                syslog_formatter = logging.Formatter('%(name)s[%(process)d]: %(message)s')
                syslog_handler.setFormatter(syslog_formatter)

                # Map custom NOTICE level to syslog LOG_NOTICE
                syslog_handler.priority_map['NOTICE'] = 'notice'

                logger.addHandler(syslog_handler)
                print(f"Syslog handler added: {addr}")
                break
            except Exception as e:
                print(f"Failed to add syslog handler {addr}: {e}")
                continue

        if not syslog_handler:
            print("WARNING: Failed to setup syslog handler")
    except Exception as e:
        print(f"ERROR: Syslog setup failed: {e}")

    # Stream handler (console)
    stream_handler = logging.StreamHandler()
    stream_handler.setLevel(logging.INFO)
    stream_formatter = logging.Formatter(
        '%(asctime)s.%(msecs)03d [%(name)s][%(levelname)s] %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    stream_handler.setFormatter(stream_formatter)
    logger.addHandler(stream_handler)

    return logger

logger = setup_logger('raw2bmp')

# Global flag for graceful shutdown
running = True

COMMON_RESOLUTIONS = [
    (1920, 1080), (1280, 720), (3840, 2160), (2560, 1440),
    (1280, 960), (640, 480), (1920, 1200), (2048, 1536),
]

PIXEL_FORMATS = ["yuyv422", "rgba"]


def signal_handler(signum, frame):
    """Handle shutdown signals gracefully"""
    global running
    running = False
    logger.info(f"Received signal {signum}, shutting down...")
    print(f"\nReceived signal {signum}, shutting down...")


def auto_detect_format(file_path):
    """Auto-detect resolution and pixel format from file size"""
    file_size = file_path.stat().st_size

    # Try common resolutions
    for width, height in COMMON_RESOLUTIONS:
        for pixel_format in PIXEL_FORMATS:
            expected_size = width * height * (4 if pixel_format == "rgba" else 2)
            if file_size == expected_size:
                return width, height, pixel_format

    # Calculate from file size
    pixels_yuyv = file_size // 2
    if file_size % 2 == 0:
        possible_width = int(math.sqrt(pixels_yuyv * 16 / 9))
        possible_height = pixels_yuyv // possible_width
        if possible_width * possible_height * 2 == file_size:
            return possible_width, possible_height, "yuyv422"

    pixels_rgba = file_size // 4
    if file_size % 4 == 0:
        possible_width = int(math.sqrt(pixels_rgba * 16 / 9))
        possible_height = pixels_rgba // possible_width
        if possible_width * possible_height * 4 == file_size:
            return possible_width, possible_height, "rgba"

    return None, None, None


def convert_rgba(raw_path, bmp_path, width, height):
    """Convert RGBA to BMP"""
    raw_data = np.fromfile(raw_path, dtype=np.uint8)
    expected_size = width * height * 4

    if raw_data.size != expected_size:
        if raw_data.size < expected_size:
            raw_data = np.pad(raw_data, (0, expected_size - raw_data.size), 'constant')
        else:
            raw_data = raw_data[:expected_size]

    img_array = raw_data.reshape((height, width, 4))
    img = Image.fromarray(img_array, 'RGBA')
    img.convert('RGB').save(bmp_path, 'BMP')


def convert_yuyv422(raw_path, bmp_path, width, height):
    """Convert YUYV422 to BMP"""
    raw_data = np.fromfile(raw_path, dtype=np.uint8)
    expected_size = width * height * 2

    if raw_data.size != expected_size:
        if raw_data.size < expected_size:
            raw_data = np.pad(raw_data, (0, expected_size - raw_data.size), 'constant')
        else:
            raw_data = raw_data[:expected_size]

    yuyv = raw_data.reshape((height, width // 2, 4))

    y0 = yuyv[:, :, 0].astype(np.float32)
    u = yuyv[:, :, 1].astype(np.float32)
    y1 = yuyv[:, :, 2].astype(np.float32)
    v = yuyv[:, :, 3].astype(np.float32)

    u_full = np.repeat(u, 2, axis=1)
    v_full = np.repeat(v, 2, axis=1)

    y_full = np.zeros((height, width), dtype=np.float32)
    y_full[:, 0::2] = y0
    y_full[:, 1::2] = y1

    r = y_full + 1.402 * (v_full - 128)
    g = y_full - 0.344136 * (u_full - 128) - 0.714136 * (v_full - 128)
    b = y_full + 1.772 * (u_full - 128)

    rgb = np.stack([r, g, b], axis=2)
    rgb = np.clip(rgb, 0, 255).astype(np.uint8)

    Image.fromarray(rgb, 'RGB').save(bmp_path, 'BMP')


def process_single_file(args):
    """Process a single file (worker function)"""
    raw_file, watch_dir, output_dir, delete_after = args

    raw_path = Path(watch_dir) / raw_file
    marker_path = raw_path.with_suffix(raw_path.suffix + ".processed")

    # Skip if already processed
    if marker_path.exists():
        return None, "skipped"

    try:
        # Auto-detect
        width, height, pixel_format = auto_detect_format(raw_path)

        if width is None:
            return raw_file, "no_format"

        # Convert
        bmp_path = Path(output_dir) / f"{raw_path.stem}.bmp"

        if pixel_format == "rgba":
            convert_rgba(raw_path, bmp_path, width, height)
        elif pixel_format == "yuyv422":
            convert_yuyv422(raw_path, bmp_path, width, height)
        else:
            return raw_file, "error"

        # Delete raw file
        if delete_after:
            raw_path.unlink()
            if marker_path.exists():
                marker_path.unlink()
        else:
            marker_path.touch()

        return raw_file, f"success:{width}x{height}:{pixel_format}"

    except Exception as e:
        return raw_file, f"error:{str(e)}"


def process_batch(verbose=True):
    """Process all raw files in watch directory (single batch)

    Returns:
        tuple: (total, success, failed, skipped, elapsed)
    """
    watch_path = Path(WATCH_DIR)
    output_path = Path(OUTPUT_DIR)

    watch_path.mkdir(parents=True, exist_ok=True)
    if OUTPUT_DIR != WATCH_DIR:
        output_path.mkdir(parents=True, exist_ok=True)

    # Get all raw files
    raw_files = sorted([f.name for f in watch_path.glob("*.raw")])

    if not raw_files:
        return 0, 0, 0, 0, 0.0

    total = len(raw_files)
    logger.info(f"Found {total} raw files to process")

    # Flush all handlers
    for handler in logger.handlers:
        handler.flush()

    # Start timer
    start_time = time.time()

    # Prepare arguments
    args_list = [(f, WATCH_DIR, OUTPUT_DIR, DELETE_RAW_AFTER_CONVERT) for f in raw_files]

    # Process in parallel
    with mp.Pool(processes=NUM_JOBS) as pool:
        results = pool.map(process_single_file, args_list)

    # End timer
    elapsed = time.time() - start_time

    # Analyze results
    success = 0
    failed = 0
    skipped = 0

    for filename, status in results:
        if filename is None:
            skipped += 1
        elif status.startswith("success"):
            success += 1
            _, resolution, fmt = status.split(":")
            logger.info(f"Converted: {filename} ({resolution} {fmt.upper()})")
            if verbose:
                print(f"\033[0;32m[OK]\033[0m {filename} ({resolution} {fmt.upper()})")
        elif status == "no_format":
            failed += 1
            logger.warning(f"Cannot detect format: {filename}")
            if verbose:
                print(f"\033[0;31m[SKIP]\033[0m {filename} - Cannot detect format")
        else:
            failed += 1
            logger.error(f"Conversion failed: {filename} - {status}")
            if verbose:
                print(f"\033[0;31m[FAIL]\033[0m {filename}")

    # Flush all handlers to ensure logs are written
    for handler in logger.handlers:
        handler.flush()

    return total, success, failed, skipped, elapsed


def run_once():
    """Run conversion once and exit"""
    logger.info("Raw Image to BMP Converter - Single Run Mode")
    logger.notice(f"Watch Directory: {WATCH_DIR}, Parallel Jobs: {NUM_JOBS}, Delete after: {DELETE_RAW_AFTER_CONVERT}")

    print("=" * 60)
    print("Raw Image to BMP Converter - Single Run Mode")
    print("=" * 60)
    print(f"Watch Directory:  {WATCH_DIR}")
    print(f"Parallel Jobs:    {NUM_JOBS}")
    print(f"Delete after:     {DELETE_RAW_AFTER_CONVERT}")
    print("=" * 60)
    print()

    total, success, failed, skipped, elapsed = process_batch(verbose=True)

    if total == 0:
        logger.warning("No .raw files found")
        print("No .raw files found")
        return

    logger.notice(f"Conversion complete: Total={total}, Success={success}, Failed={failed}, Skipped={skipped}, Time={elapsed:.3f}s")

    print()
    print("=" * 60)
    print("Conversion Summary")
    print("=" * 60)
    print(f"Total:        {total} files")
    print(f"Success:      {success} files")
    print(f"Failed:       {failed} files")
    print(f"Skipped:      {skipped} files")
    print(f"Time:         {elapsed:.3f}s")
    if total > 0:
        print(f"Avg/file:     {elapsed/total:.3f}s")
    print(f"Parallelism:  {NUM_JOBS} jobs")
    print("=" * 60)


def run_loop(interval=DEFAULT_LOOP_INTERVAL):
    """Run conversion in loop mode"""
    global running

    # Setup signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    logger.info("Raw Image to BMP Converter - Loop Mode started")
    logger.notice(f"Watch Directory: {WATCH_DIR}, Parallel Jobs: {NUM_JOBS}, Interval: {interval}s")

    print("=" * 60)
    print("Raw Image to BMP Converter - Loop Mode")
    print("=" * 60)
    print(f"Watch Directory:  {WATCH_DIR}")
    print(f"Parallel Jobs:    {NUM_JOBS}")
    print(f"Delete after:     {DELETE_RAW_AFTER_CONVERT}")
    print(f"Loop Interval:    {interval}s")
    print("=" * 60)
    print("Press Ctrl+C to stop...")
    print()

    total_processed = 0
    total_success = 0
    total_failed = 0
    loop_count = 0

    while running:
        loop_count += 1
        total, success, failed, skipped, elapsed = process_batch(verbose=False)

        if total > 0:
            total_processed += total
            total_success += success
            total_failed += failed
            logger.notice(f"Loop {loop_count}: Processed {total} files (OK:{success}, FAIL:{failed}) in {elapsed:.3f}s")
            print(f"[Loop {loop_count}] Processed {total} files (OK:{success}, FAIL:{failed}) in {elapsed:.3f}s")

        # Wait for next iteration
        wait_start = time.time()
        while running and (time.time() - wait_start) < interval:
            time.sleep(0.1)

    # Print summary on exit
    logger.info(f"Loop Mode stopped. Total processed: {total_processed}, Success: {total_success}, Failed: {total_failed}")
    print()
    print("=" * 60)
    print("Loop Mode Summary")
    print("=" * 60)
    print(f"Total Loops:      {loop_count}")
    print(f"Total Processed:  {total_processed} files")
    print(f"Total Success:    {total_success} files")
    print(f"Total Failed:     {total_failed} files")
    print("=" * 60)


def main():
    """Main entry point with argument parsing"""
    parser = argparse.ArgumentParser(
        description='Raw Image to BMP Converter - Auto Detection + Parallel Processing',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s                    # Single run mode (default)
  %(prog)s --loop             # Loop mode with 1s interval
  %(prog)s --loop -i 2        # Loop mode with 2s interval
  %(prog)s -l -i 0.5          # Loop mode with 0.5s interval
        '''
    )
    parser.add_argument(
        '-l', '--loop',
        action='store_true',
        help='Run in loop mode (continuously watch for new files)'
    )
    parser.add_argument(
        '-i', '--interval',
        type=float,
        default=DEFAULT_LOOP_INTERVAL,
        help=f'Loop interval in seconds (default: {DEFAULT_LOOP_INTERVAL})'
    )

    args = parser.parse_args()

    if args.loop:
        run_loop(interval=args.interval)
    else:
        run_once()


if __name__ == "__main__":
    main()
