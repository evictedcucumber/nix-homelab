# Shared by every user. Hosts stay minimal, so docs that Home Manager adds by default are off.
{
  home.stateVersion = "26.11";

  programs.bash.enable = true;
  programs.man.enable = false;
  manual.manpages.enable = false;
  news.display = "silent";
}
