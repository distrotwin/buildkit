#include <cstdio>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
int main(){
  std::vector<std::string> v{"kylin","uos","deepin"};
  std::mutex m; int n=0;
  std::thread th([&]{ std::lock_guard<std::mutex> g(m); for(auto&s:v) n+=s.size(); });
  th.join();
  std::printf("ok %d\n", n);
  return 0;
}
