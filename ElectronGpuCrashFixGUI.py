#!/usr/bin/env python3
"""
Electron GPU Crash Fix GUI — Dark theme tkinter interface
Uses theyonecodes-toolkit DarkTheme for consistent styling.
"""

import sys
import os
import subprocess
import threading
import json
import winreg
from pathlib import Path
from datetime import datetime

# Add toolkit to path
toolkit_path = Path(__file__).parent / "vendor" / "toolkit"
if toolkit_path.exists():
    sys.path.insert(0, str(toolkit_path))

import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext, filedialog

# Import DarkTheme from toolkit
try:
    from toolkit.gui.dark_theme import (
        apply_dark_theme, create_dark_button, create_dark_frame,
        create_dark_label, create_dark_combobox, create_dark_treeview,
        create_dark_progressbar, create_dark_separator, create_dark_entry,
        BG, BG2, BG3, FG, FG2, ACCENT, GREEN, RED, AMBER, GRAY,
        BORDER, FONT, FONT_BOLD, FONT_TITLE, FONT_MONO,
        STATUS_COLORS
    )
    HAS_TOOLKIT = True
except ImportError:
    HAS_TOOLKIT = False
    # Fallback colors
    BG = "#0D1117"
    BG2 = "#161B22"
    BG3 = "#1C2128"
    FG = "#E6EDF3"
    FG2 = "#8B949E"
    ACCENT = "#58A6FF"
    GREEN = "#3FB950"
    RED = "#F85149"
    AMBER = "#D29922"
    GRAY = "#8B949E"
    BORDER = "#30363D"
    FONT = ("Segoe UI", 10)
    FONT_BOLD = ("Segoe UI", 10, "bold")
    FONT_TITLE = ("Segoe UI", 16, "bold")
    FONT_MONO = ("Consolas", 10)
    STATUS_COLORS = {"PASS": GREEN, "FAIL": RED, "WARNING": AMBER, "PENDING": GRAY}


class ElectronGpuCrashFixGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("Electron GPU Crash Fix — 0x80000003")
        self.root.minsize(900, 650)
        self.root.configure(bg=BG)
        self.root.state("zoomed")
        
        self.ps_script = Path(__file__).parent / "installer" / "install-electron-ifeo-and-task.ps1"
        self.shim_path = Path.home() / "Desktop" / "ElectronShim.exe"
        self.log_path = Path(os.environ.get("PROGRAMDATA", "C:\\ProgramData")) / "ElectronGpuCrashFix.log"
        self.running_task = None
        
        self._build_ui()
        self._load_initial_state()
    
    def _build_ui(self):
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(3, weight=1)
        
        # ========== ROW 0: Header ==========
        header = tk.Frame(self.root, bg=BG2, height=56, highlightthickness=0)
        header.grid(row=0, column=0, sticky="ew")
        header.grid_propagate(False)
        
        tk.Label(header, text="ELECTRON GPU CRASH FIX", bg=BG2, fg=ACCENT,
                 font=FONT_TITLE).pack(side=tk.LEFT, padx=25, pady=14)
        tk.Label(header, text="0x80000003 (STATUS_BREAKPOINT)", bg=BG2, fg=FG2,
                 font=FONT_MONO).pack(side=tk.LEFT, padx=(0, 14), pady=14)
        
        # Status indicators
        status_frame = tk.Frame(header, bg=BG2)
        status_frame.pack(side=tk.RIGHT, padx=25, pady=14)
        
        self.backup_status = tk.Label(status_frame, text="BACKUP: ON" if HAS_TOOLKIT else "BACKUP: OFF",
                                      bg=BG2, fg=GREEN if HAS_TOOLKIT else AMBER,
                                      font=FONT_MONO)
        self.backup_status.pack(side=tk.LEFT, padx=(0, 12))
        
        self.admin_status = tk.Label(status_frame, text="ADMIN: YES" if self._is_admin() else "ADMIN: NO",
                                     bg=BG2, fg=GREEN if self._is_admin() else RED,
                                     font=FONT_MONO)
        self.admin_status.pack(side=tk.LEFT)
        
        # Shim status
        self.shim_status = tk.Label(status_frame, text="SHIM: FOUND" if self.shim_path.exists() else "SHIM: MISSING",
                                    bg=BG2, fg=GREEN if self.shim_path.exists() else RED,
                                    font=FONT_MONO)
        self.shim_status.pack(side=tk.LEFT, padx=(12, 0))
        
        # ========== ROW 1: Toolbar ==========
        toolbar = tk.Frame(self.root, bg=BG, highlightthickness=0)
        toolbar.grid(row=1, column=0, sticky="ew", padx=20, pady=(16, 4))
        toolbar.columnconfigure(1, weight=1)
        
        # Shim path selector
        shim_frame = tk.Frame(toolbar, bg=BG3, highlightthickness=1, highlightbackground=BORDER)
        shim_frame.grid(row=0, column=0, sticky="w", padx=(0, 8))
        shim_frame.columnconfigure(1, weight=1)
        
        tk.Label(shim_frame, text="Shim:", bg=BG3, fg=FG2, font=FONT).grid(row=0, column=0, padx=(8, 4))
        self.shim_var = tk.StringVar(value=str(self.shim_path))
        self.shim_entry = create_dark_entry(shim_frame, textvariable=self.shim_var, width=40)
        self.shim_entry.grid(row=0, column=1, padx=(4, 4), pady=4, sticky="ew")
        
        browse_btn = create_dark_button(shim_frame, "BROWSE", self._browse_shim, variant="ghost", width=8)
        browse_btn.grid(row=0, column=2, padx=(0, 8), pady=4)
        
        # Right side - actions
        if HAS_TOOLKIT:
            jej_btn = create_dark_button(toolbar, "JEV TRIAGE", self._run_jev_triage, variant="warn")
            jej_btn.grid(row=0, column=2, padx=(8, 0), sticky="e")
        
        backup_btn = create_dark_button(toolbar, "VIEW BACKUPS", self._view_backups, variant="ghost")
        backup_btn.grid(row=0, column=3, padx=(8, 0), sticky="e")
        
        # ========== ROW 2: App List ==========
        list_frame = tk.Frame(self.root, bg=BG2, highlightthickness=1, highlightbackground=BORDER)
        list_frame.grid(row=2, column=0, sticky="nsew", padx=20, pady=(8, 4))
        list_frame.columnconfigure(0, weight=1)
        list_frame.rowconfigure(0, weight=1)
        
        # App treeview
        columns = ("name", "status", "ifeo_path", "risk")
        self.tree = create_dark_treeview(list_frame, columns=columns, show="headings")
        
        self.tree.heading("name", text="Application", anchor="w")
        self.tree.heading("status", text="IFEO Status", anchor="center")
        self.tree.heading("ifeo_path", text="IFEO Registry Path", anchor="w")
        self.tree.heading("risk", text="Risk", anchor="center")
        
        self.tree.column("name", width=180, minwidth=150)
        self.tree.column("status", width=120, minwidth=100)
        self.tree.column("ifeo_path", width=400, minwidth=300)
        self.tree.column("risk", width=70, minwidth=60)
        
        # Scrollbars
        vscroll = ttk.Scrollbar(list_frame, orient="vertical", command=self.tree.yview,
                                style="Dark.Vertical.TScrollbar")
        hscroll = ttk.Scrollbar(list_frame, orient="horizontal", command=self.tree.xview,
                                style="Dark.Horizontal.TScrollbar")
        self.tree.configure(yscrollcommand=vscroll.set, xscrollcommand=hscroll.set)
        
        self.tree.grid(row=0, column=0, sticky="nsew", padx=(4, 0), pady=4)
        vscroll.grid(row=0, column=1, sticky="ns", pady=4)
        hscroll.grid(row=1, column=0, sticky="ew", padx=4)
        
        # Bind selection
        self.tree.bind("<<TreeviewSelect>>", self._on_select)
        self.tree.bind("<Double-1>", lambda e: self._toggle_selected())
        
        # Populate apps
        self._all_apps = self._get_default_apps()
        self._populate_tree()
        
        # ========== ROW 3: Action Bar & Log ==========
        bottom = tk.Frame(self.root, bg=BG)
        bottom.grid(row=3, column=0, sticky="ew", padx=20, pady=(4, 16))
        bottom.columnconfigure(0, weight=1)
        bottom.rowconfigure(1, weight=1)
        
        # Action buttons
        action_frame = tk.Frame(bottom, bg=BG)
        action_frame.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        
        self.register_btn = create_dark_button(action_frame, "REGISTER SELECTED", self._register_selected, variant="accent")
        self.register_btn.pack(side=tk.LEFT, padx=(0, 8))
        
        self.register_all_btn = create_dark_button(action_frame, "REGISTER ALL", self._register_all, variant="warn")
        self.register_all_btn.pack(side=tk.LEFT, padx=(0, 8))
        
        self.unregister_btn = create_dark_button(action_frame, "UNREGISTER SELECTED", self._unregister_selected, variant="danger")
        self.unregister_btn.pack(side=tk.LEFT, padx=(0, 8))
        
        self.dryrun_btn = create_dark_button(action_frame, "DRY RUN", self._dry_run, variant="ghost")
        self.dryrun_btn.pack(side=tk.RIGHT, padx=(8, 0))
        
        self.task_btn = create_dark_button(action_frame, "INSTALL SCHEDULED TASK", self._install_task, variant="ghost")
        self.task_btn.pack(side=tk.RIGHT)
        
        # Progress bar
        self.progress_var = tk.DoubleVar()
        self.progress = create_dark_progressbar(bottom, variable=self.progress_var, maximum=100)
        self.progress.grid(row=1, column=0, sticky="ew", pady=(0, 8))
        
        # Log area
        log_frame = tk.Frame(bottom, bg=BG2, highlightthickness=1, highlightbackground=BORDER)
        log_frame.grid(row=2, column=0, sticky="nsew")
        log_frame.columnconfigure(0, weight=1)
        log_frame.rowconfigure(0, weight=1)
        
        self.log_text = scrolledtext.ScrolledText(
            log_frame, bg=BG, fg=FG, font=FONT_MONO,
            insertbackground=FG, selectbackground=ACCENT, selectforeground="#FFFFFF",
            highlightthickness=0, bd=0, wrap=tk.WORD
        )
        self.log_text.grid(row=0, column=0, sticky="nsew", padx=4, pady=4)
        self.log_text.configure(state=tk.DISABLED)
        
        # Context menu
        self._create_context_menu()
    
    def _create_context_menu(self):
        self.context_menu = tk.Menu(self.root, tearoff=0, bg=BG2, fg=FG,
                                    activebackground=ACCENT, activeforeground="#FFFFFF",
                                    font=FONT)
        self.context_menu.add_command(label="Register", command=self._register_selected)
        self.context_menu.add_command(label="Unregister", command=self._unregister_selected)
        self.context_menu.add_separator()
        self.context_menu.add_command(label="Open IFEO Registry Key", command=self._open_registry)
        self.context_menu.add_command(label="View Backup Info", command=self._view_backup_info)
        
        def show_context(event):
            item = self.tree.identify_row(event.y)
            if item:
                self.tree.selection_set(item)
                self.context_menu.post(event.x_root, event.y_root)
        
        self.tree.bind("<Button-3>", show_context)
    
    def _is_admin(self):
        try:
            import ctypes
            return ctypes.windll.shell32.IsUserAnAdmin() != 0
        except:
            return False
    
    def _get_default_apps(self):
        """Define default Electron apps to monitor."""
        return [
            {"name": "Discord.exe", "risk": "LOW", "desc": "Discord chat app"},
            {"name": "Code.exe", "risk": "LOW", "desc": "VS Code editor"},
            {"name": "Obsidian.exe", "risk": "LOW", "desc": "Obsidian note-taking"},
            {"name": "Notion.exe", "risk": "LOW", "desc": "Notion workspace"},
            {"name": "electron.exe", "risk": "MEDIUM", "desc": "Generic Electron binary"},
            {"name": "Resolve.exe", "risk": "MEDIUM", "desc": "DaVinci Resolve"},
            {"name": "Spotify.exe", "risk": "LOW", "desc": "Spotify music"},
            {"name": "Slack.exe", "risk": "LOW", "desc": "Slack messaging"},
            {"name": "Teams.exe", "risk": "LOW", "desc": "Microsoft Teams"},
            {"name": "Figma.exe", "risk": "LOW", "desc": "Figma design"},
            {"name": "Postman.exe", "risk": "LOW", "desc": "Postman API client"},
            {"name": "WhatsApp.exe", "risk": "LOW", "desc": "WhatsApp Desktop"},
        ]
    
    def _populate_tree(self):
        for item in self.tree.get_children():
            self.tree.delete(item)
        
        for i, app in enumerate(self._all_apps):
            # Check current IFEO status
            status, ifeo_path = self._check_ifeo_status(app["name"])
            
            status_color = {"REGISTERED": GREEN, "NOT REGISTERED": AMBER, "ERROR": RED}.get(status, FG2)
            
            item_id = self.tree.insert("", "end", values=(
                app["name"], status, ifeo_path, app["risk"]
            ), tags=(f"status_{status.lower().replace(' ', '_')}", app["name"]))
            
            # Alternate row colors
            if i % 2 == 0:
                self.tree.item(item_id, tags=(f"status_{status.lower().replace(' ', '_')}", app["name"], "even"))
        
        # Configure tags
        self.tree.tag_configure("status_registered", foreground=GREEN)
        self.tree.tag_configure("status_not_registered", foreground=AMBER)
        self.tree.tag_configure("status_error", foreground=RED)
        self.tree.tag_configure("even", background=BG3)
    
    def _check_ifeo_status(self, app_name):
        """Check if IFEO Debugger is registered for this app."""
        key_path = rf"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\{app_name}"
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path) as key:
                debugger, _ = winreg.QueryValueEx(key, "Debugger")
                if "ElectronShim" in debugger:
                    return "REGISTERED", f"HKLM\\{key_path} → {debugger}"
                else:
                    return "OTHER DEBUGGER", f"HKLM\\{key_path} → {debugger}"
        except FileNotFoundError:
            return "NOT REGISTERED", f"HKLM\\{key_path} (not found)"
        except Exception as e:
            return "ERROR", str(e)
    
    def _on_select(self, event):
        selection = self.tree.selection()
        if selection:
            item = self.tree.item(selection[0])
            app_name = item["tags"][1] if len(item["tags"]) > 1 else None
            if app_name:
                app = next((a for a in self._all_apps if a["name"] == app_name), None)
                if app:
                    status, ifeo_path = self._check_ifeo_status(app_name)
                    self._log(f"Selected: {app_name} [{app['risk']}] — {status}")
                    self._log(f"  IFEO: {ifeo_path}")
                    if app.get("desc"):
                        self._log(f"  Description: {app['desc']}")
    
    def _register_selected(self):
        selection = self.tree.selection()
        if not selection:
            messagebox.showwarning("No Selection", "Please select at least one app")
            return
        
        apps = [self.tree.item(s)["tags"][1] for s in selection if len(self.tree.item(s)["tags"]) > 1]
        self._run_registration(apps)
    
    def _register_all(self):
        apps = [app["name"] for app in self._all_apps]
        if not messagebox.askyesno("Register All", f"Register IFEO for all {len(apps)} apps?\n\nThis will create registry backups before each change."):
            return
        self._run_registration(apps)
    
    def _unregister_selected(self):
        selection = self.tree.selection()
        if not selection:
            messagebox.showwarning("No Selection", "Please select at least one app")
            return
        
        apps = [self.tree.item(s)["tags"][1] for s in selection if len(self.tree.item(s)["tags"]) > 1]
        if not messagebox.askyesno("Unregister", f"Unregister IFEO for {len(apps)} selected apps?\n\nThis will remove the Debugger values and restore from backup if available."):
            return
        self._run_unregistration(apps)
    
    def _dry_run(self):
        """Run dry-run with Jev Router triage."""
        if not HAS_TOOLKIT or not (toolkit_path / "jev-router" / "jev_router.py").exists():
            messagebox.showwarning("Dry Run", "Jev Router not available in toolkit")
            return
        
        apps = [app["name"] for app in self._all_apps]
        self._log("=== DRY RUN + JEV TRIAGE ===")
        
        def worker():
            try:
                context = {
                    "task_type": "electron_ifeo_registration",
                    sensitive = True,
                    target_apps = apps,
                    required_capabilities = ["system_admin", "registry", "ifeo"]
                }
                context_json = json.dumps(context)
                
                result = subprocess.run(
                    [sys.executable, str(toolkit_path / "jev-router" / "jev_router.py"),
                     "--choice", "system_optimization", "--context", context_json],
                    capture_output=True, text=True, timeout=30
                )
                
                if result.returncode == 0:
                    decision = json.loads(result.stdout)
                    self._log(f"Jev Model: {decision.get('model_name', 'N/A')}")
                    self._log(f"Confidence: {decision.get('confidence', 0)*100:.0f}%")
                    self._log(f"Reasoning: {decision.get('reasoning', 'N/A')}")
                    if decision.get('requires_human'):
                        self._log("⚠ HUMAN REVIEW REQUIRED", level="warn")
                    if decision.get('triggered_guardrails'):
                        self._log(f"Guardrails: {', '.join(decision['triggered_guardrails'])}")
                else:
                    self._log(f"Jev error: {result.stderr}", level="error")
            except Exception as e:
                self._log(f"Jev error: {e}", level="error")
        
        threading.Thread(target=worker, daemon=True).start()
    
    def _run_registration(self, apps):
        if not apps:
            return
        
        shim = self.shim_var.get().strip()
        if not shim:
            messagebox.showerror("Error", "Shim path is empty")
            return
        
        if not Path(shim).exists():
            if not messagebox.askyesno("Shim Not Found", f"ElectronShim.exe not found at:\n{shim}\n\nContinue anyway?"):
                return
        
        self.register_btn.configure(state=tk.DISABLED)
        self.register_all_btn.configure(state=tk.DISABLED)
        self.unregister_btn.configure(state=tk.DISABLED)
        self.progress_var.set(0)
        
        def worker():
            try:
                self._log(f"=== REGISTERING {len(apps)} APP(S) ===")
                self._log(f"Shim: {shim}")
                self._log(f"BackupEngine: {'ON' if HAS_TOOLKIT else 'OFF'}")
                
                for i, app in enumerate(apps):
                    self._log(f"[{i+1}/{len(apps)}] {app}...")
                    key_path = rf"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\{app}"
                    
                    if HAS_TOOLKIT:
                        try:
                            # Run PowerShell with BackupEngine
                            ps_cmd = f"""
                            Import-Module "{toolkit_path}/backup-engine/powershell/BackupEngine.psm1" -Force -ErrorAction SilentlyContinue
                            $key = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\{app}"
                            if (-not (Test-Path $key)) {{ New-Item -Path $key -Force | Out-Null }}
                            $result = Invoke-WithBackup -ToolName "electron-gpu-crash-fix" -Description "Register IFEO for {app}" -RegistryKeys $key -ActionScriptBlock {{ Set-ItemProperty -Path $key -Name 'Debugger' -Value '{shim}' }}
                            Write-Output "BACKUP_DIR:$($result.BackupDir)"
                            """
                            result = subprocess.run(
                                ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_cmd],
                                capture_output=True, text=True, timeout=30
                            )
                            
                            if result.returncode == 0:
                                backup_dir = "unknown"
                                for line in result.stdout.split('\n'):
                                    if line.startswith("BACKUP_DIR:"):
                                        backup_dir = line.split(":", 1)[1].strip()
                                self._log(f"  ✓ {app} (backup: {backup_dir})")
                            else:
                                self._log(f"  ✗ {app} FAILED: {result.stderr}", level="error")
                        except Exception as e:
                            self._log(f"  ✗ {app} EXCEPTION: {e}", level="error")
                    else:
                        # Fallback without backup
                        try:
                            with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, key_path) as key:
                                winreg.SetValueEx(key, "Debugger", 0, winreg.REG_SZ, shim)
                            self._log(f"  + {app} (NO BACKUP)")
                        except Exception as e:
                            self._log(f"  ✗ {app} FAILED: {e}", level="error")
                    
                    # Update tree status
                    self.root.after(0, lambda a=app: self._update_app_status(a))
                    self.progress_var.set((i + 1) / len(apps) * 100)
                
                self._log("=== REGISTRATION COMPLETE ===")
                self._log("Restart affected apps to apply changes.")
                
            except Exception as e:
                self._log(f"ERROR: {e}", level="error")
            finally:
                self.root.after(0, self._reset_buttons)
        
        threading.Thread(target=worker, daemon=True).start()
    
    def _run_unregistration(self, apps):
        if not apps:
            return
        
        self.register_btn.configure(state=tk.DISABLED)
        self.register_all_btn.configure(state=tk.DISABLED)
        self.unregister_btn.configure(state=tk.DISABLED)
        
        def worker():
            try:
                self._log(f"=== UNREGISTERING {len(apps)} APP(S) ===")
                
                for i, app in enumerate(apps):
                    self._log(f"[{i+1}/{len(apps)}] Unregistering {app}...")
                    key_path = rf"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\{app}"
                    
                    if HAS_TOOLKIT:
                        try:
                            ps_cmd = f"""
                            Import-Module "{toolkit_path}/backup-engine/powershell/BackupEngine.psm1" -Force -ErrorAction SilentlyContinue
                            $key = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\{app}"
                            $result = Invoke-WithBackup -ToolName "electron-gpu-crash-fix" -Description "Unregister IFEO for {app}" -RegistryKeys $key -ActionScriptBlock {{ if (Test-Path $key) {{ Remove-Item -Path $key -Force -Recurse }} }}
                            Write-Output "BACKUP_DIR:$($result.BackupDir)"
                            """
                            result = subprocess.run(
                                ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_cmd],
                                capture_output=True, text=True, timeout=30
                            )
                            
                            if result.returncode == 0:
                                self._log(f"  ✓ {app} unregistered")
                            else:
                                self._log(f"  ✗ {app} FAILED: {result.stderr}", level="error")
                        except Exception as e:
                            self._log(f"  ✗ {app} EXCEPTION: {e}", level="error")
                    else:
                        try:
                            winreg.DeleteKey(winreg.HKEY_LOCAL_MACHINE, key_path)
                            self._log(f"  - {app} unregistered (NO BACKUP)")
                        except Exception as e:
                            self._log(f"  ✗ {app} FAILED: {e}", level="error")
                    
                    self.root.after(0, lambda a=app: self._update_app_status(a))
                
                self._log("=== UNREGISTRATION COMPLETE ===")
                
            except Exception as e:
                self._log(f"ERROR: {e}", level="error")
            finally:
                self.root.after(0, self._reset_buttons)
        
        threading.Thread(target=worker, daemon=True).start()
    
    def _install_task(self):
        if not messagebox.askyesno("Install Scheduled Task", 
            "This will install a SYSTEM-level scheduled task that runs every 30 minutes\n"
            "to auto-detect and register newly-installed Electron apps.\n\n"
            "The task runs ElectronAutoRegister.ps1 with BackupEngine protection.\n\nContinue?"):
            return
        
        def worker():
            try:
                self._log("=== INSTALLING SCHEDULED TASK ===")
                
                script_path = self.ps_script
                ps_cmd = f"""
                $scriptPath = "{script_path}"
                $startBoundary = (Get-Date).Date.AddDays(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Auto-detect newly-installed Electron apps and add IFEO Debugger entries. Runs as SYSTEM every 30 min with BackupEngine protection.</Description>
    <URI>\\ElectronAutoRegister</URI>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT30M</Interval>
        <Duration>P1825D</Duration>
        <StopAtDurationEnd>true</StopAtDurationEnd>
      </Repetition>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <AllowStartIfOnBatteries>true</AllowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$scriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
                $xmlPath = Join-Path $env:TEMP "ElectronAutoRegister-task.xml"
                [System.IO.File]::WriteAllText($xmlPath, $taskXml, [System.Text.Encoding]::Unicode)
                schtasks.exe /Delete /TN ElectronAutoRegister /F 2>&1 | Out-Null
                $reg = schtasks.exe /Create /XML $xmlPath /TN ElectronAutoRegister /F 2>&1
                if ($LASTEXITCODE -eq 0) {{ Write-Output "SUCCESS" }} else {{ Write-Output "FAILED:$reg" }}
                Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
                """
                
                result = subprocess.run(
                    ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_cmd],
                    capture_output=True, text=True, timeout=30
                )
                
                if "SUCCESS" in result.stdout:
                    self._log("  ✓ Scheduled task installed: ElectronAutoRegister (SYSTEM, every 30 min)")
                else:
                    self._log(f"  ✗ Failed: {result.stdout}", level="error")
                
            except Exception as e:
                self._log(f"ERROR: {e}", level="error")
        
        threading.Thread(target=worker, daemon=True).start()
    
    def _run_jev_triage(self):
        if not HAS_TOOLKIT or not (toolkit_path / "jev-router" / "jev_router.py").exists():
            messagebox.showwarning("Jev Router", "Jev Router not available in toolkit")
            return
        
        apps = [app["name"] for app in self._all_apps]
        self._log("=== JEV TRIAGE ===")
        
        def worker():
            try:
                context = {
                    "task_type": "electron_ifeo_registration",
                    "sensitive": True,
                    "target_apps": apps,
                    "required_capabilities": ["system_admin", "registry", "ifeo"]
                }
                context_json = json.dumps(context)
                
                result = subprocess.run(
                    [sys.executable, str(toolkit_path / "jev-router" / "jev_router.py"),
                     "--choice", "system_optimization", "--context", context_json],
                    capture_output=True, text=True, timeout=30
                )
                
                if result.returncode == 0:
                    decision = json.loads(result.stdout)
                    self._log(f"Jev Model: {decision.get('model_name', 'N/A')}")
                    self._log(f"Confidence: {decision.get('confidence', 0)*100:.0f}%")
                    self._log(f"Reasoning: {decision.get('reasoning', 'N/A')}")
                    if decision.get('requires_human'):
                        self._log("⚠ HUMAN REVIEW REQUIRED", level="warn")
                    if decision.get('triggered_guardrails'):
                        self._log(f"Guardrails: {', '.join(decision['triggered_guardrails'])}")
                else:
                    self._log(f"Jev error: {result.stderr}", level="error")
            except Exception as e:
                self._log(f"Jev error: {e}", level="error")
        
        threading.Thread(target=worker, daemon=True).start()
    
    def _browse_shim(self):
        path = filedialog.askopenfilename(
            title="Select ElectronShim.exe",
            filetypes=[("Executable", "*.exe"), ("All Files", "*.*")]
        )
        if path:
            self.shim_var.set(path)
            self.shim_path = Path(path)
            self.shim_status.config(text="SHIM: FOUND", fg=GREEN)
            self._log(f"Shim path updated: {path}")
    
    def _view_backups(self):
        backup_root = Path.home() / "ToolBackups"
        if backup_root.exists():
            backups = sorted(backup_root.glob("*electron-gpu-crash-fix*"), 
                           key=lambda p: p.stat().st_mtime, reverse=True)[:10]
            msg = "Recent electron-gpu-crash-fix backups:\n\n"
            for b in backups:
                manifest = b / "MANIFEST.csv"
                if manifest.exists():
                    lines = manifest.read_text().strip().split('\n')
                    msg += f"{b.name}: {len(lines)-1} registry keys\n"
                else:
                    msg += f"{b.name}: (no manifest)\n"
            if not backups:
                msg = "No electron-gpu-crash-fix backups found"
        else:
            msg = "No backups found"
        messagebox.showinfo("Backup History", msg)
    
    def _open_registry(self):
        selection = self.tree.selection()
        if not selection:
            return
        item = self.tree.item(selection[0])
        app_name = item["tags"][1] if len(item["tags"]) > 1 else None
        if app_name:
            key_path = rf"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\{app_name}"
            try:
                subprocess.run(["regedit", "/v", key_path], check=False)
                self._log(f"Opened registry: {key_path}")
            except Exception as e:
                self._log(f"Failed to open registry: {e}", level="error")
    
    def _view_backup_info(self):
        self._view_backups()
    
    def _update_app_status(self, app_name):
        """Refresh the tree item for this app."""
        for item_id in self.tree.get_children():
            item = self.tree.item(item_id)
            if item["tags"] and len(item["tags"]) > 1 and item["tags"][1] == app_name:
                status, ifeo_path = self._check_ifeo_status(app_name)
                self.tree.item(item_id, values=(app_name, status, ifeo_path, 
                                                next(a["risk"] for a in self._all_apps if a["name"] == app_name)))
                break
    
    def _load_initial_state(self):
        self._log("Electron GPU Crash Fix GUI started")
        self._log(f"BackupEngine: {'ON' if HAS_TOOLKIT else 'OFF'}")
        self._log(f"Admin Rights: {'YES' if self._is_admin() else 'NO'}")
        self._log(f"Shim: {self.shim_path} ({'FOUND' if self.shim_path.exists() else 'MISSING'})")
        self._log(f"Toolkit: {toolkit_path}")
        
        # Initial status check
        def worker():
            for app in self._all_apps:
                status, _ = self._check_ifeo_status(app["name"])
                self.root.after(0, lambda a=app, s=status: self._update_app_status(a["name"]))
        
        threading.Thread(target=worker, daemon=True).start()
    
    def _log(self, message, level="info"):
        self.root.after(0, lambda: self._append_log(message, level))
    
    def _append_log(self, message, level="info"):
        self.log_text.configure(state=tk.NORMAL)
        timestamp = datetime.now().strftime("%H:%M:%S")
        color_map = {"info": FG, "warn": AMBER, "error": RED, "ok": GREEN}
        color = color_map.get(level, FG)
        
        self.log_text.insert(tk.END, f"[{timestamp}] {message}\n")
        self.log_text.see(tk.END)
        self.log_text.configure(state=tk.DISABLED)
        
        # Also write to file
        try:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | {message}\n")
        except:
            pass
    
    def _reset_buttons(self):
        self.register_btn.configure(state=tk.NORMAL)
        self.register_all_btn.configure(state=tk.NORMAL)
        self.unregister_btn.configure(state=tk.NORMAL)
        self.progress_var.set(0)
    
    def _toggle_selected(self):
        """Double-click toggles register/unregister."""
        selection = self.tree.selection()
        if not selection:
            return
        item = self.tree.item(selection[0])
        app_name = item["tags"][1] if len(item["tags"]) > 1 else None
        if app_name:
            status = item["values"][1]
            if status == "REGISTERED":
                self._unregister_selected()
            else:
                self._register_selected()


def main():
    root = tk.Tk()
    
    # Apply dark theme if toolkit available
    if HAS_TOOLKIT:
        apply_dark_theme(root)
    else:
        root.configure(bg=BG)
        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure("Treeview", background=BG2, foreground=FG, fieldbackground=BG2,
                       borderwidth=0, font=FONT, rowheight=28)
        style.map("Treeview", background=[("selected", ACCENT)], foreground=[("selected", "#FFFFFF")])
        style.configure("Treeview.Heading", background=BG3, foreground=FG, font=FONT_BOLD,
                       borderwidth=1, relief="flat")
    
    app = ElectronGpuCrashFixGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()