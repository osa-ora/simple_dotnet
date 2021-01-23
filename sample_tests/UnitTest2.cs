using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Tests
{
    [TestClass]
    public class UnitTest2
    {
        [TestMethod]
        public void TestMethod1()
        {
	    bool result =false;
            Assert.IsFalse(result, "Test1 false .. ");
        }
        [TestMethod]
        public void TestMethod2()
        {
            bool result = true;
            Assert.IsTrue(result, "Test2 false .. ");
        }
    }
}
